#import "Basic";

OPENSSL_INIT_SETTINGS :: struct {};

OPENSSL_INIT_ADD_ALL_CIPHERS       :: 0x00000004;
OPENSSL_INIT_ADD_ALL_DIGESTS       :: 0x00000008;

OPENSSL_init_crypto :: (opts: u64, settings: *OPENSSL_INIT_SETTINGS) -> s32 #foreign libssl;
OpenSSL_add_all_algorithms :: () -> s32 #expand {
    return OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS, null);
}

OPENSSL_INIT_LOAD_CRYPTO_STRINGS   :: 0x00000002;
OPENSSL_INIT_LOAD_SSL_STRINGS      :: 0x00200000;

OPENSSL_init_ssl :: (opts: u64, settings: *OPENSSL_INIT_SETTINGS) -> s32 #foreign libssl;
SSL_load_error_strings :: () -> s32 #expand {
    return OPENSSL_init_ssl(OPENSSL_INIT_LOAD_CRYPTO_STRINGS | OPENSSL_INIT_LOAD_SSL_STRINGS, null);
}

SSL_METHOD :: struct {};
TLS_client_method :: () -> *SSL_METHOD #foreign libssl;

SSL_CTX :: struct {};
SSL_CTX_new :: (meth: *SSL_METHOD) -> *SSL_CTX #foreign libssl;
SSL_CTX_free :: (ctx: *SSL_CTX) #foreign libssl;

ssl_print_errors :: () {
    while true {
        err := ERR_get_error();
        if err <= 0 break;

        print("ssl_error: %\n", to_string(ERR_error_string(err, null)));
    }
}

SSL_SENT_SHUTDOWN :: 1;
SSL_RECEIVED_SHUTDOWN :: 2;

SSL :: struct {};
SSL_new  :: (ctx: *SSL_CTX) -> *SSL #foreign libssl;
SSL_free :: (ssl: *SSL) #foreign libssl;
SSL_set_fd :: (ssl: *SSL, fd: s32) -> s32 #foreign libssl;
SSL_connect :: (ssl: *SSL) -> s32 #foreign libssl;
SSL_read  :: (ssl: *SSL, buf: *u8, num: s32) -> s32 #foreign libssl;
SSL_write :: (ssl: *SSL, buf: *u8, num: s32) -> s32 #foreign libssl;
SSL_set_shutdown :: (ssl: *SSL, mode: s32) #foreign libssl;
SSL_shutdown :: (ssl: *SSL) -> s32 #foreign libssl;

ERR_get_error :: () -> u64 #foreign libssl;
ERR_error_string :: (e: u64, buf: *u8) -> *u8 #foreign libssl;

libssl :: #system_library "libssl";
libcrypto :: #system_library,link_always "libcrypto";
