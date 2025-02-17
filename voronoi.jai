#import "Basic";
#import "Socket";
#import "System";
#import "POSIX";
#import "String";
#import "Math";
#import "Flat_Pool";
#import "Thread";

#import "Window_Creation";
#import "Input";
Simp :: #import "Simp";

#import "OpenSSL";

GEMINI_PORT         :: "1965";
GEMINI_URI_PREFIX   :: "gemini://";
GEMINI_URI_MAX_SIZE :: 1024;
GEMTEXT_LINK_PREFIX :: "=>";
BACKGROUND_COLOR    :: Vector4.{0x18/255., 0x18/255., 0x18/255., 1};

shift :: inline (xs: *[]$T) -> T {
    assert(xs.count > 0);
    result := xs.data;
    xs.data += 1;
    xs.count -= 1;
    return result.*;
}

ssl_log_errors :: () {
    while true {
        err := ERR_get_error();
        if err <= 0 break;
        log_error("ssl_error: %\n", to_string(ERR_error_string(err, null)));
    }
}

extract_host_from_gemini_url :: (url: string) -> (host: string, ok: bool) {
    if !begins_with(url, GEMINI_URI_PREFIX) {
        log_error("Invalid URL `%`: Does not start with `%`", url, GEMINI_URI_PREFIX);
        return "", false;
    }

    host := url;
    host.data  += GEMINI_URI_PREFIX.count;
    host.count -= GEMINI_URI_PREFIX.count;
    _, host = split_from_left(host, #char "/");
    return host, true;
}

make_gemini_query :: (ctx: *SSL_CTX, url: string) -> (response: string, ok: bool) {
    log("Querying url %", url);
    host, ok := extract_host_from_gemini_url(url);
    if !ok return "", false;

    hints := addrinfo.{
        ai_family   = AF_INET,
        ai_socktype = .STREAM,
        ai_protocol = .TCP,
    };

    addrs: *addrinfo;
    gai := getaddrinfo(to_c_string(host), GEMINI_PORT, *hints, *addrs);
    if (gai != 0) {
        log_error("Could not get address of `%`: %\n", host, to_string(gai_strerror(gai)));
        return "", false;
    }
    defer freeaddrinfo(addrs);

    sd : s32 = 0;
    addr := addrs;
    while addr != null {
        sd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);

        if sd == -1 {
            _, description := get_error_value_and_string();
            log_error("Could not create socket: %", description);
            return "", false;
        }
        if connect(sd, addr.ai_addr, addr.ai_addrlen) == 0 break;

        close(sd);
        sd = -1;

        addr = addr.ai_next;
    }

    if sd == -1 {
        _, description := get_error_value_and_string();
        log_error("Could not find suitable address for %:%\n", host, GEMINI_PORT);
        return "", false;
    }
    defer close(sd);

    log("Created connection to %", to_string(addr.ai_addr.(*sockaddr_in)));

    ssl := SSL_new(ctx);
    if ssl == null {
        ssl_log_errors();
        return "", false;
    }
    defer SSL_free(ssl);

    if SSL_set_fd(ssl, sd) <= 0 {
        ssl_log_errors();
        return "", false;
    }

    if SSL_connect(ssl) <= 0 {
        ssl_log_errors();
        return "", false;
    }

    defer {
        SSL_set_shutdown(ssl, SSL_RECEIVED_SHUTDOWN | SSL_SENT_SHUTDOWN);
        SSL_shutdown(ssl);
    }

    sb : String_Builder;
    append(*sb, url);
    append(*sb, "\r\n");
    request := builder_to_string(*sb);

    // TODO: maybe write in a loop to ensure everything's written?
    if SSL_write(ssl, request.data, xx request.count) <= 0 {
        ssl_log_errors();
        return "", false;
    }

    buffer: [1024]u8;
    n := SSL_read(ssl, buffer.data, buffer.count);
    while n > 0 {
        append(*sb, buffer.data, n);
        n = SSL_read(ssl, buffer.data, buffer.count);
    }

    if n < 0 {
        reset(*sb);
        ssl_log_errors();
        return "", false;
    }

    return builder_to_string(*sb), true;
}

Page_Item :: struct {
    kind: enum {
        TEXT;
        LINK;
    };
    text: string;
    link: string;
}

Page :: struct {
    loading := false;

    items: [..]Page_Item;
    items_pool: Flat_Pool; // All the strings of items are allocated in this pool so you can dispose all of them at once

    scroll_y: int;

    // From https://geminiprotocol.net/docs/protocol-specification.gmi#requests
    // >When making a request, the URI MUST NOT exceed 1024 bytes, and
    // >a server MUST reject requests where the URI exceeds this
    // >limit. A server MUST reject a request with a userinfo portion.
    //
    // So we are taking advantage of that and just make the page
    // struct own the bytes of the url so we can simplify the memory
    // management.
    url_data: [GEMINI_URI_MAX_SIZE]u8;
    url_count: int;
}

page_set_url :: inline (using page: *Page, url: string) {
    url_count = min(url.count, GEMINI_URI_MAX_SIZE);
    memcpy(url_data.data, url.data, url_count);
}

page_get_url :: inline (using page: Page) -> string {
    return .{data = url_data.data, count = url_count};
}

start_query_thread :: () {
    init(*page_mutex);
    init(*query_semaphore);
    ok := thread_init(*query_thread, (thread: *Thread) -> s64 {
        while true {
            wait_for(*query_semaphore);

            lock(*page_mutex);
                assert(!page.loading);
                page.loading = true;
                url := copy_string(page_get_url(page),, allocator = temp); // Making a copy of URL so we can access it outside of page_mutex while making a request
            unlock(*page_mutex);

            response, ok := make_gemini_query(ctx, url);

            lock(*page_mutex);
                page.loading = false;
                page.scroll_y = 0;
                reset(*page.items_pool, overwrite_memory=true);
                page.items.count = 0;

                items_pool_allocator: Allocator;
                items_pool_allocator.proc = flat_pool_allocator_proc;
                items_pool_allocator.data = *page.items_pool;
                if ok {
                    original_response_to_free_at_the_end_of_parsing := response;
                    while response.count > 0 {
                        line: string;
                        _, line, response = split_from_left(response, #char "\n");
                        line = copy_string(line,, allocator = items_pool_allocator);
                        if begins_with(line, GEMTEXT_LINK_PREFIX) {
                            link       := line;
                            link.data  += GEMTEXT_LINK_PREFIX.count;
                            link.count -= GEMTEXT_LINK_PREFIX.count;
                            link        = trim_left(link);
                            _, link = split_from_left_by_any(link, " \t");
                            array_add(*page.items, .{
                                kind = .LINK,
                                text = line,
                                link = link,
                            });
                        } else {
                            array_add(*page.items, .{
                                kind = .TEXT,
                                text = line,
                            });
                        }
                    }
                    free(original_response_to_free_at_the_end_of_parsing);
                } else {
                    // TODO: Print exact network error
                    // It could be extracted from make_gemini_query()
                    array_add(*page.items, .{
                        kind = .TEXT,
                        text = "# Network error while loading the page",
                    });
                    array_add(*page.items, .{
                        kind = .LINK,
                        text = "=> gemini://geminiprotocol.net/ Go to the official Gemini Protocol website",
                        link = "gemini://geminiprotocol.net/",
                    });
                }
            unlock(*page_mutex);

            reset_temporary_storage();
        }

        return 0;
    });
    assert(ok);
    thread_start(*query_thread);
}

Page_Action :: struct {
    type: enum {
        NONE;
        CLICK_LINK;
    };
    link: string;
}

font : *Simp.Dynamic_Font;
mouse_click := false;
mouse_x := 0;
mouse_y := 0;
window_width  := 1600;
window_height := 900;
max_content_width := 780;
ctx: *SSL_CTX;
page: Page;
page_mutex: Mutex;
query_thread: Thread;
query_semaphore: Semaphore;

immediate_page :: (page: Page) -> (action: Page_Action) {
    action: Page_Action;

    content_width := min(max_content_width, window_width);

    line_padding := 10;

    // TODO: horizontal scroll
    //   Is it really needed if we are wrapping words?
    // TODO: smooth vertical scroll (scroll velocity)
    // TODO: vertical scroll bar
    if page.loading {
        Simp.set_shader_for_color();
        SPINNER_SIZE :: 50;
        SPINNER_COLOR :: Vector4.{1, 1, 1, 1};
        SPINNER_PADDING :: 30;
        cx := window_width/2;
        cy := window_height/2;
        ps : [4]Vector2;
        a  : float = xx seconds_since_init()*4.0;
        for *ps {
            it.x = cx + cos(a)*SPINNER_SIZE;
            it.y = cy + sin(a)*SPINNER_SIZE;
            a += PI/2.0;
        }
        Simp.immediate_quad(ps[0], ps[1], ps[2], ps[3], SPINNER_COLOR);
    }

    text_x := window_width/2 - content_width/2;
    text_y := page.scroll_y + font.character_height + line_padding;
    for item: page.items {
        if text_y > window_height + font.character_height break;
        color := Vector4.{1, 1, 1, 1};
        // TODO: the hitbox of a link does not take into account word wrapping
        if item.kind == .LINK && text_y - font.character_height <= mouse_y && mouse_y <= text_y {
            color = .{1, 0, 0, 1};
            if mouse_click {
                if begins_with(item.link, "gemini://") {
                    action = .{
                        type = .CLICK_LINK,
                        link = item.link,
                    };
                } else if begins_with(item.link, "https://") {
                    log("TODO: implement opening Web links in the default browser");
                } else {
                    action = .{
                        type = .CLICK_LINK,
                        link = join(page_get_url(page), item.link,, allocator = temp),  // TODO: better handling of relative links
                    };
                }
            }
        }
        Simp.begin_prepare_text(font);
        for split(item.text, " ",, allocator = temp) {
            // TODO: word wrap overshoots a word
            // We should probably introduce some sort of rollback for append_prepare_text
            Simp.append_prepare_text(font, it);
            Simp.append_prepare_text(font, " ");
            if font.temporary_glyphs_width_in_pixels >= content_width {
                Simp.end_prepare_text(font);
                Simp.draw_prepared_text(font, text_x, text_y, color);
                text_y += font.character_height + line_padding;
                Simp.begin_prepare_text(font);
            }
        }
        Simp.end_prepare_text(font);
        Simp.draw_prepared_text(font, text_x, text_y, color);
        text_y += font.character_height + line_padding;
    }

    return action;
}

main :: () {
    path := path_strip_filename(get_path_of_running_executable());
    set_working_directory(path);

    args := get_command_line_arguments();
    program_name := shift(*args);

    if args.count <= 0 {
        print("Usage: % <URL>\n", program_name);
        print("ERROR: expected gemini URL\n");
        exit(1);
    }
    url_from_command_line_arguments := shift(*args);

    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    ctx = SSL_CTX_new(TLS_client_method());
    if ctx == null {
        ssl_log_errors();
        exit(1);
    }
    defer SSL_CTX_free(ctx);

    page_set_url(*page, url_from_command_line_arguments);
    start_query_thread();
    signal(*query_semaphore);

    the_window := create_window(window_width, window_height, "Voronoi");

    font_size :: 28;
    font = Simp.get_font_at_size(".", "./resources/Alegreya-Regular.ttf", font_size);
    assert(font != null);

    quit := false;
    while !quit {
        mouse_click = false;

        update_window_events();
        for get_window_resizes() {
            Simp.update_window(the_window);
            if it.window == the_window {
                window_width  = it.width;
                window_height = it.height;
            }
        }
        wheel_delta := 0;
        for events_this_frame {
            if it.type == {
                case .QUIT; quit = true;
                case .KEYBOARD; if it.key_code == .MOUSE_BUTTON_LEFT && !it.key_pressed {
                    mouse_click = true;
                }
                case .MOUSE_WHEEL; {
                    SCROLL_DELTA :: 100;
                    if it.wheel_delta < 0 {
                        wheel_delta -= SCROLL_DELTA;
                    } else if it.wheel_delta > 0 {
                        wheel_delta += SCROLL_DELTA;
                    }
                }
                case; print("%\n", it);
            }
        }

        mouse_x, mouse_y = get_mouse_pointer_position();

        Simp.set_render_target(the_window, .LEFT_HANDED);
        {
            using BACKGROUND_COLOR;
            Simp.clear_render_target(x, y, z, w);
        }

        // TODO: render cool background from https://github.com/tsoding/voronoi-opengl
        lock(*page_mutex);
            page.scroll_y = min(page.scroll_y + wheel_delta, 0);
            // TODO: bottom scroll limit

            action := immediate_page(page);
            if #complete action.type == {
                case .NONE;
                case .CLICK_LINK;
                    if page.loading {
                        log_error("TODO: Cannot query while loading");
                    } else {
                        page_set_url(*page, action.link);
                        signal(*query_semaphore);
                    }
            }
        unlock(*page_mutex);

        Simp.swap_buffers(the_window);

        sleep_milliseconds(10);
        reset_temporary_storage();
    }
}
