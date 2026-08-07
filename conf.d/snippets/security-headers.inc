# Included from each app's server block. Kept as .inc so the conf.d/*.conf glob
# does not try to load it as a standalone config.
#
# These live at server level, not per-location. nginx's add_header does not
# merge across levels: a location that sets any add_header of its own drops
# every inherited one. So an app fragment must either add no headers at all
# (the normal case — every location is a plain proxy) or re-include this file.

add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options SAMEORIGIN always;
add_header Referrer-Policy no-referrer-when-downgrade always;
