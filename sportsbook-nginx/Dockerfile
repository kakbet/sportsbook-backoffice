# sportsbook-nginx/Dockerfile (Mevcut dosyanız ile aynı olmalı)
# Note: build context for Dockerfile needs to be project root!
FROM nginx:1.17-alpine AS builder

# Install git
RUN set -eux \
    && apk add --no-cache git

RUN mkdir -p /home/www-data
WORKDIR /home/www-data

# Multi-repository build'den gelen www klasörünü kopyala
COPY www /home/www-data/www
RUN find /home/www-data -type f -name "*.sql" -exec truncate -s 0 {} \;
RUN rm -rf /home/www-data/www/.git
# no need to have all code here, filename is enough
# keeps the image small and doesn't leak our code.

#
# to effectively have a small image, we must use a 2-stage-build
# (otherwise layers just add up)
#
FROM nginx:1.17-alpine AS production
RUN mkdir -p /home/www-data
COPY --from=builder /home/www-data /home/www-data
COPY --chown=nginx:nginx sportsbook-nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=nginx:nginx sportsbook-nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
RUN mkdir -p /home/www-data/www/.tmp
RUN chown nginx:nginx -R /home/www-data/