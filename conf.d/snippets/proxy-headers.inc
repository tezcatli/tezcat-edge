# The forwarding headers every proxied location needs. Included per-location,
# because an app fragment's locations are not all proxies (a redirect or a
# static block would not want these).
#
# X-Forwarded-Proto is the one that matters beyond logging: the app behind this
# only ever sees plain HTTP, so without it, anything that builds an absolute URL
# from the request scheme emits http:// links into an https:// page.

proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
