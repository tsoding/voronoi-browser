#import "Basic";
#import "Socket";
#import "System";
#import "POSIX";
#import "String";

#import "OpenSSL";

GEMINI_PORT :: "1965";

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

make_gemini_query_and_print_response :: (url: string) -> (ok: bool) {
    host, ok := extract_host_from_gemini_url(url);
    if !ok return false;

    hints := addrinfo.{
        ai_family   = AF_INET,
        ai_socktype = .STREAM,
        ai_protocol = .TCP,
    };

    addrs: *addrinfo;
    gai := getaddrinfo(to_c_string(host,, allocator=temp), GEMINI_PORT, *hints, *addrs);
    if (gai != 0) {
        log_error("Could not get address of `%`: %\n", host, to_string(gai_strerror(gai)));
        return false;
    }
    defer freeaddrinfo(addrs);

    sd : s32 = 0;
    addr := addrs;
    while addr != null {
        sd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);

        if sd == -1 {
            _, description := get_error_value_and_string();
            log_error("Could not create socket: %", description);
            return false;
        }
        if connect(sd, addr.ai_addr, addr.ai_addrlen) == 0 break;

        close(sd);
        sd = -1;

        addr = addr.ai_next;
    }

    if sd == -1 {
        _, description := get_error_value_and_string();
        log_error("Could not find suitable address for %:%\n", host, GEMINI_PORT);
        return false;
    }

    log("Created connection to %", to_string(addr.ai_addr.(*sockaddr_in)));

    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    ctx := SSL_CTX_new(TLS_client_method());
    if ctx == null {
        ssl_log_errors();
        return false;
    }
    defer SSL_CTX_free(ctx);

    ssl := SSL_new(ctx);
    if ssl == null {
        ssl_log_errors();
        return false;
    }
    defer SSL_free(ssl);

    if SSL_set_fd(ssl, sd) <= 0 {
        ssl_log_errors();
        return false;
    }

    if SSL_connect(ssl) <= 0 {
        ssl_log_errors();
        return false;
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
        return false;
    }

    buffer: [1024]u8;
    n := SSL_read(ssl, buffer.data, buffer.count);
    while n > 0 {
        s : string = ---;
        s.data = buffer.data;
        s.count = n;
        print("%", s);
        n = SSL_read(ssl, buffer.data, buffer.count);
    }

    if n < 0 {
        ssl_log_errors();
        return false;
    }

    return true;
}

main :: () {
    args := get_command_line_arguments();
    program_name := shift(*args);

    if args.count <= 0 {
        print("Usage: % <URL>\n", program_name);
        print("ERROR: expected gemini URL\n");
        exit(1);
    }
    url := shift(*args);

    if !make_gemini_query_and_print_response(url) then exit(1);
}
