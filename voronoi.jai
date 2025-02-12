#import "Basic";
#import "Socket";
#import "System";
#import "POSIX";
#import "String";

#import "OpenSSL";

PORT :: "1965";

shift :: (xs: *[]string) -> string {
    assert(xs.count > 0);
    result := xs.data;
    xs.data += 1;
    xs.count -= 1;
    return result.*;
}

main :: () {
    args := get_command_line_arguments();

    program_name := shift(*args);

    if args.count <= 0 {
        print("Usage: % <URL>\n", program_name);
        print("ERROR: expected gemini URL\n");
        exit(69);
    }

    url := shift(*args);

    gemini_prefix :: "gemini://";
    if !begins_with(url, gemini_prefix) {
        print("ERROR: Invalid URL: Does not start with %", gemini_prefix);
        exit(1);
    }

    host := url;
    host.data  += gemini_prefix.count;
    host.count -= gemini_prefix.count;
    _, host = split_from_left(host, #char "/");
    host_cstr := to_c_string(host,, allocator=temp);

    hints := addrinfo.{
        ai_family   = AF_INET,
        ai_socktype = .STREAM,
        ai_protocol = .TCP,
    };

    addrs: *addrinfo;
    gai := getaddrinfo(host_cstr, PORT, *hints, *addrs);
    if (gai != 0) {
        print("Could not get address of `%`: %\n", host_cstr, gai_strerror(gai));
        exit(1);
    }
    defer freeaddrinfo(addrs);

    sd : s32 = 0;
    addr := addrs;
    while addr != null {
        sd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);

        if sd == -1 {
            _, description := get_error_value_and_string();
            print("Could not create socket: %", description);
            exit(1);
        }
        if connect(sd, addr.ai_addr, addr.ai_addrlen) == 0 break;

        close(sd);
        sd = -1;

        addr = addr.ai_next;
    }

    if sd == -1 {
        _, description := get_error_value_and_string();
        print("Could not find suitable address for %:%\n", host, PORT);
        exit(1);
    }

    print("Created connection to %\n", to_string(addr.ai_addr.(*sockaddr_in)));

    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    ctx := SSL_CTX_new(TLS_client_method());
    if ctx == null {
        ssl_print_errors();
        exit(1);
    }
    // defer SSL_CTX_free(ctx);

    ssl := SSL_new(ctx);
    if ssl == null {
        ssl_print_errors();
        exit(1);
    }
    defer SSL_free(ssl);

    SSL_set_fd(ssl, sd);
    if (SSL_connect(ssl) < 0) {
        ssl_print_errors();
        exit(1);
    }

    sb : String_Builder;
    append(*sb, url);
    append(*sb, "\r\n");
    request := builder_to_string(*sb);

    SSL_write(ssl, request.data, xx request.count);

    buffer: [1024]u8;
    n := SSL_read(ssl, buffer.data, buffer.count);
    while n > 0 {
        s : string = ---;
        s.data = buffer.data;
        s.count = n;
        print("%", s);
        n = SSL_read(ssl, buffer.data, buffer.count);
    }

    // defer {
    //     SSL_set_shutdown(ssl, SSL_RECEIVED_SHUTDOWN | SSL_SENT_SHUTDOWN);
    //     SSL_shutdown(ssl);
    // }
}
