#import "Basic";
#import "Socket";
#import "System";
#import "POSIX";
#import "String";
#import "Math";

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
    gai := getaddrinfo(to_c_string(host,, allocator=temp), GEMINI_PORT, *hints, *addrs);
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
    url := shift(*args);

    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    ctx := SSL_CTX_new(TLS_client_method());
    if ctx == null {
        ssl_log_errors();
        exit(1);
    }
    defer SSL_CTX_free(ctx);

    response, ok := make_gemini_query(ctx, url);
    if !ok then exit(1);
    response_lines := split(response, "\n");

    window_width  := 1600;
    window_height := 900;
    the_window := create_window(window_width, window_height, "Voronoi");

    font_size := 48;
    line_padding := 10;
    font := Simp.get_font_at_size(".", "./resources/Alegreya-Regular.ttf", font_size);
    assert(font != null);

    quit := false;
    while !quit {
        click := false;

        update_window_events();
        for get_window_resizes() {
            Simp.update_window(the_window);
            if it.window == the_window {
                window_width  = it.width;
                window_height = it.height;
            }
        }
        for events_this_frame {
            if it.type == .QUIT then quit = true;
            if it.type == .KEYBOARD && it.key_code == .MOUSE_BUTTON_LEFT && !it.key_pressed {
                click = true;
            }
        }

        mouse_x, mouse_y := get_mouse_pointer_position();

        Simp.set_render_target(the_window, .LEFT_HANDED);
        {
            using BACKGROUND_COLOR;
            Simp.clear_render_target(x, y, z, w);
        }
        
        text_x := line_padding;
        text_y := font_size + line_padding;
        for line: response_lines {
            text_width := Simp.prepare_text(font, line);
            color := Vector4.{1, 1, 1, 1};
            link_prefix :: "=> ";
            if begins_with(line, link_prefix) {
                if text_y - font_size <= mouse_y && mouse_y <= text_y {
                    color = .{1, 0, 0, 1};
                    if click {
                        link := line;
                        link.data  += link_prefix.count;
                        link.count -= link_prefix.count;
                        _, link = split_from_left_by_any(link, " \t");
                        if begins_with(link, "gemini://") {
                            // TODO: absolute gemini links
                            url = link;
                            response, ok = make_gemini_query(ctx, url);
                            if !ok then exit(1); // TODO: we should probably not exit on errors here
                            response_lines = split(response, "\n");
                        } else if begins_with(link, "https://") {
                            log("TODO: implement opening Web links in the default browser");
                        } else {
                            url = join(url, link); // TODO: address the memory leak
                            response, ok = make_gemini_query(ctx, url);
                            if !ok then exit(1); // TODO: we should probably not exit on errors here
                            response_lines = split(response, "\n");
                        }
                    }
                }
            }
            Simp.draw_prepared_text(font, text_x, text_y, color);
            text_y += font_size + line_padding;
        }

        Simp.swap_buffers(the_window);

        sleep_milliseconds(10);
        reset_temporary_storage();
    }
}

// TODO: cool background from https://github.com/tsoding/voronoi-opengl
