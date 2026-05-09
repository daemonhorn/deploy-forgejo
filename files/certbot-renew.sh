#!/bin/sh
# Runs inside the certbot container. Issues initial cert then renews every 12h.
set -e
trap "exit 0" TERM

certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --preferred-profile shortlived \
    --ip-address "$DOMAIN"

while :; do
    sleep 12h &
    wait $!
    certbot renew --quiet --webroot --webroot-path=/var/www/certbot \
        --preferred-profile shortlived
done
