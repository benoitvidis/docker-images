// Varnish 4 style - eZ 5.4+ / 2014.09+
// Complete VCL example

vcl 4.0;
import std;

// Our Backend - Assuming that web server is listening on port 80
// Replace the host to fit your setup
backend ezpublish {
    .host = "web";
    .port = "80";
}

// ACL for invalidators IP
acl invalidators {
    "127.0.0.1";
    "192.168.1.0"/24;
    "web";
    "cli";
}

// ACL for debuggers IP
acl debuggers {
    "127.0.0.1";
    "192.168.1.0"/24;
    "web";
    "cli";
    "172.17.0.0"/8; //docker
}

// Called at the beginning of a request, after the complete request has been received
sub vcl_recv {

    // Set real IP header
    if (!req.http.X-Real-IP) {
        // Check if we are behind a proxy
        if (req.http.x-forwarded-for) {
            set req.http.X-Real-IP = regsub(req.http.x-forwarded-for,"^(([0-9]{1,3}\.){3}[0-9]{1,3}),(.*)$", "\1");
        }
        else {
            set req.http.X-Real-IP = client.ip;
        }
    }

    // Set real Host header (force host if we are behind a proxy)
    if (req.http.x-forwarded-host) {
        set req.http.host = req.http.x-forwarded-host;
    }

    // If you have a round robin configuration, use the following conf to set the backend :
    /*
    if (req.http.host ~ "admin.mysite.com") { // Will force the backend for back office
        set req.backend_hint = apache1_preprod;
    } else {
        set req.backend_hint = rr.backend();
    }
    */

    // Set the backend
    set req.backend_hint = ezpublish;

    // Uncomment if you want to bypass varnish cache with specific header
    /*
    if (std.ip(req.http.X-Real-IP, "0.0.0.0") ~ debuggers || std.ip(req.http.X-Real-IP, "0.0.0.0") ~ invalidators) {
        if (req.http.X-Bypass == "true") {
            return (pass);
        }
    }
    */

    //Uncomment if you want to allow your customer to force cache miss in his browser when hitting Ctrl + F5
    //Warning : this will cause Varnish to create a new cache version and not replace the old one
    //Please read the doc before using this : http://book.varnish-software.com/4.0/chapters/Cache_Invalidation.html#force-cache-misses
    /*
    if (std.ip(req.http.X-Real-IP, "0.0.0.0") ~ refreshers && req.http.Cache-Control ~ "no-cache") {
        set req.hash_always_miss = true;
    }
    */

    //If you need to vary page/ESI on cookie name, you can use example below
    /*
    if (req.http.Cookie !~ "my_cookie_name") {
        set req.http.X-Custom-Header = "false";
    }
    else
    {
        set req.http.X-Custom-Header = "true";
    }
    */

    // Advertise Symfony for ESI support (Disabled for Back office Preview)
    if(!req.url ~ "/content/versionview/") {
       set req.http.Surrogate-Capability = "abc=ESI/1.0";
    }

    // Prevent client actions on cache policy
    if (std.ip(req.http.X-Real-IP, "0.0.0.0") !~ debuggers) {
        unset req.http.Pragma;
        unset req.http.Cache-control;
    }

    // Add a unique header containing the client address (only for master request)
    // Please note that /_fragment URI can change in Symfony configuration
    if (!req.url ~ "^/_fragment") {
        if (req.http.x-forwarded-for) {
            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    // Trigger cache purge if needed
    call ez_purge;

    // Don't cache requests other than GET and HEAD.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    // Normalize the Accept-Encoding headers
    if (req.http.Accept-Encoding) {
        if (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    # Don't cache symfony toolbar
    if (req.url ~ "^/_(profiler|wdt)") {
        return (pass);
    }

    // Do a standard lookup on assets
    // Note that file extension list below is not extensive, so consider completing it to fit your needs.
    if (req.url ~ "\.(css|js|gif|jpe?g|bmp|png|tiff?|ico|img|tga|wmf|svg|swf|ico|mp3|mp4|m4a|ogg|mov|avi|wmv|zip|gz|pdf|ttf|eot|wof)$") {
        return (hash);
    }

    // Retrieve client user hash and add it to the forwarded request.
    call ez_user_hash;

    // If it passes all these tests, do a lookup anyway.
    return (hash);
}

// Called when the requested object has been retrieved from the backend
sub vcl_backend_response {

    if (bereq.http.accept ~ "application/vnd.fos.user-context-hash"
        && beresp.status >= 500
    ) {
        return (abandon);
    }

    // Optimize to only parse the Response contents from Symfony
    if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
        unset beresp.http.Surrogate-Control;
        set beresp.do_esi = true;
    }

    // Allow stale content, in case the backend goes down or cache is not fresh any more
    // make Varnish keep all objects for 1 hours beyond their TTL
    set beresp.grace = 1h;

    // Only cache file with less than 1Mb size
    if (std.integer(beresp.http.Content-Length, 0) > 1048576)
    {
        set beresp.uncacheable = true;
    }

    // Add TTL header
    set beresp.http.X-ttl = beresp.ttl;

    //Always Vary on Authorization
    //You can disable this only if you will never use AuthType in Apache for your project
    if (!beresp.http.Vary ~ "Authorization")
    {
        set beresp.http.Vary = beresp.http.Vary+ ", Authorization";
    }
}

// Handle purge
// You may add FOSHttpCacheBundle tagging rules
// See http://foshttpcache.readthedocs.org/en/latest/varnish-configuration.html#id4
sub ez_purge {

    if (req.method == "BAN") {
        if (!client.ip ~ invalidators) {
            return (synth(405, "Method not allowed - ip: "+ client.ip));
        }

        if (req.http.X-Location-Id) {
            if ( req.http.X-Location-Id == "*" ) {
                // Purge all locations
                ban( "obj.http.X-Location-Id ~ ^[0-9]+$" );
                if (client.ip ~ debuggers) {
                    set req.http.X-Debug = "Purge all locations done.";
                }
            } else {
                // Purge location by its locationId
                ban( "obj.http.X-Location-Id ~ \b" + req.http.X-Location-Id +"\b");
                if (client.ip ~ debuggers) {
                    set req.http.X-Debug = "Purge of content connected to the location id(" + req.http.X-Location-Id + ") done.";
                }
            }
        } elseif ( req.http.X-Match ) {
             ban( "req.url ~ " + req.http.X-Match );
             if (client.ip ~ debuggers) {
                 set req.http.X-Debug = "Purge of urls " + req.http.X-Match + " done";
             }
        }

        // necessary, otherwise the request goes through to the website
        return (synth(200, "Banned"));
    }
}

// Sub-routine to get client user hash, for context-aware HTTP cache.
sub ez_user_hash {

    // Prevent tampering attacks on the hash mechanism
    if (req.restarts == 0
        && (req.http.accept ~ "application/vnd.fos.user-context-hash"
            || req.http.x-user-hash
        )
    ) {
        return (synth(400));
    }

    if (req.restarts == 0 && (req.method == "GET" || req.method == "HEAD")) {
        // Anonymous user => Set a hardcoded anonymous hash
        // Kaliop hack : use "is_logged_in" cookie to test if user is anonymous => you must set the cookie after login as ez will not do it
        if (!req.http.authorization && req.http.Cookie !~ "is_logged_in") {
            set req.http.X-User-Hash = "38015b703d82206ebc01d17a39c727e5";
        }
        // Pre-authenticate request to get shared cache, even when authenticated
        else {
            set req.http.x-fos-original-url    = req.url;
            set req.http.x-fos-original-accept = req.http.accept;
            set req.http.x-fos-original-cookie = req.http.cookie;
            // Clean up cookie for the hash request to only keep session cookie, as hash cache will vary on cookie.
            set req.http.cookie = ";" + req.http.cookie;
            set req.http.cookie = regsuball(req.http.cookie, "; +", ";");
            set req.http.cookie = regsuball(req.http.cookie, ";(eZSESSID[^=]*)=", "; \1=");
            set req.http.cookie = regsuball(req.http.cookie, ";[^ ][^;]*", "");
            set req.http.cookie = regsuball(req.http.cookie, "^[; ]+|[; ]+$", "");

            set req.http.accept = "application/vnd.fos.user-context-hash";
            set req.url = "/_fos_user_context_hash";

            // Force the lookup, the backend must tell how to cache/vary response containing the user hash

            return (hash);
        }
    }

    // Rebuild the original request which now has the hash.
    if (req.restarts > 0
        && req.http.accept == "application/vnd.fos.user-context-hash"
    ) {
        set req.url         = req.http.x-fos-original-url;
        set req.http.accept = req.http.x-fos-original-accept;
        set req.http.cookie = req.http.x-fos-original-cookie;

        unset req.http.x-fos-original-url;
        unset req.http.x-fos-original-accept;
        unset req.http.x-fos-original-cookie;

        // Force the lookup, the backend must tell not to cache or vary on the
        // user hash to properly separate cached data.

        return (hash);
    }
}

sub vcl_deliver {
    // On receiving the hash response, copy the hash header to the original
    // request and restart.
    if (req.restarts == 0
        && resp.http.content-type ~ "application/vnd.fos.user-context-hash"
    ) {
        set req.http.x-user-hash = resp.http.x-user-hash;

        return (restart);
    }

    // If we get here, this is a real response that gets sent to the client.

    if(std.ip(req.http.X-Real-IP, "0.0.0.0") ~ debuggers) {
        //Show backend name in response headers
        set resp.http.X-Debug-Served-By = req.backend_hint;
        //Show X User hash in response headers
        set resp.http.X-Debug-User-Hash = req.http.x-user-hash;

        //Save Cache-Control in debug header (in case you alter it afterwards, see below)
        set resp.http.X-Debug-Cache-Control = resp.http.Cache-Control;

        if (obj.hits > 0) {
            set resp.http.X-Cache = "HIT";
            set resp.http.X-Cache-Hits = obj.hits;
        } else {
            set resp.http.X-Cache = "MISS";
        }
    }
    else
    {
        // Remove the vary on context user hash, this is nothing public. Keep all
        // other vary headers.

        set resp.http.Vary = regsub(resp.http.Vary, "(?i),? *x-user-hash *", "");
        set resp.http.Vary = regsub(resp.http.Vary, "^, *", "");

        // Sanity check to prevent ever exposing the hash to a client.
        unset resp.http.x-user-hash;

        unset resp.http.X-ttl;
    }

    //Remove shared-max-age for intermediate proxies, so that these proxies will not cache your pages
    set resp.http.Cache-Control = regsub(resp.http.Cache-Control, "(?i),? *s-maxage=[^,]*", "");

    if (resp.http.Vary == "") {
        unset resp.http.Vary;
    }
}
