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

GEMINI_PORT :: "1965";
BACKGROUND_COLOR :: Vector4.{0x18/255., 0x18/255., 0x18/255., 1};

shift :: (xs: *[]$T) -> T #expand {
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
    gemini_prefix :: "gemini://";
    if !begins_with(url, gemini_prefix) {
        log_error("Invalid URL `%`: Does not start with `%`", url, gemini_prefix);
        return "", false;
    }

    host := url;
    host.data  += gemini_prefix.count;
    host.count -= gemini_prefix.count;
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
        ssl_log_errors();
        return "", false;
    }

    return builder_to_string(*sb), true;
}


Page :: struct {
    status : enum {
        LOADING;
        LOADED;
        ERROR;
    } = .LOADED;

    text: string;
    url: string;
    scroll_y: int;
}

start_query_thread :: () {
    init(*page_mutex);
    init(*query_semaphore);
    ok := thread_init(*query_thread, (thread: *Thread) -> s64 {
        while true {
            wait_for(*query_semaphore);

            lock(*page_mutex);
                page.status = .LOADING;
            unlock(*page_mutex);

            response, ok := make_gemini_query(ctx, page.url);

            lock(*page_mutex);
                free(page.text);
                page.scroll_y = 0;
                page.text.data = null;
                page.text.count = 0;
                if ok {
                    page.status = .LOADED;
                    page.text = response;
                } else {
                    page.status = .ERROR;
                }
            unlock(*page_mutex);
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
    if page.status == {
        case .ERROR;
            text_x := window_width/2 - content_width/2;
            text_y := font.character_height + line_padding;
            Simp.prepare_text(font, "ERROR");
            Simp.draw_prepared_text(font, text_x, text_y);
        case .LOADING;
            Simp.set_shader_for_color();
            SPINNER_SIZE :: 50;
            SPINNER_COLOR :: Vector4.{1, 1, 1, 1};
            SPINNER_PADDING :: 30;
            // cx := SPINNER_SIZE + SPINNER_PADDING;
            // cy := window_height - (SPINNER_SIZE + SPINNER_PADDING);
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
            #through;
        case .LOADED;
            text_x := window_width/2 - content_width/2;
            text_y := page.scroll_y + font.character_height + line_padding;
            for line: split(page.text, "\n",, allocator = temp) {
                if text_y > window_height + font.character_height break;
                link_prefix :: "=>";
                color := Vector4.{1, 1, 1, 1};
                // TODO: the hitbox of a link does not take into account word wrapping
                if begins_with(line, link_prefix) && text_y - font.character_height <= mouse_y && mouse_y <= text_y {
                    color = .{1, 0, 0, 1};
                    if mouse_click {
                        link       := line;
                        link.data  += link_prefix.count;
                        link.count -= link_prefix.count;
                        link        = trim_left(link);
                        _, link = split_from_left_by_any(link, " \t");
                        if begins_with(link, "gemini://") {
                            action = .{
                                type = .CLICK_LINK,
                                link = link,
                            };
                        } else if begins_with(link, "https://") {
                            log("TODO: implement opening Web links in the default browser");
                        } else {
                            action = .{
                                type = .CLICK_LINK,
                                link = join(page.url, link,, allocator = temp),  // TODO: better handling of relative links
                            };
                        }
                    }
                }
                Simp.begin_prepare_text(font);
                for split(line, " ",, allocator = temp) {
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
    url_from_command_line_arguments := copy_string(shift(*args));

    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    ctx = SSL_CTX_new(TLS_client_method());
    if ctx == null {
        ssl_log_errors();
        exit(1);
    }
    defer SSL_CTX_free(ctx);

    start_query_thread();

    page.url = url_from_command_line_arguments;
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
            if action.type == {
                case .NONE;
                case .CLICK_LINK;
                    if #complete page.status == {
                        case .LOADED;
                            free(page.url);
                            page.url = copy_string(action.link);
                            signal(*query_semaphore);
                        case .LOADING;
                            log_error("TODO: Cannot query while loading");
                        case .ERROR;
                            assert(false, "TODO: unreachable");
                    }
            }
        unlock(*page_mutex);

        Simp.swap_buffers(the_window);

        sleep_milliseconds(10);
        reset_temporary_storage();
    }
}
