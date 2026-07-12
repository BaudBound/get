FROM nginx:1.29-alpine

COPY --chown=nginx:nginx deploy/get/nginx.conf /etc/nginx/nginx.conf
COPY --chown=nginx:nginx deploy/get/public/ /usr/share/nginx/html/

RUN chmod 0444 /etc/nginx/nginx.conf /usr/share/nginx/html/linux /usr/share/nginx/html/windows

USER nginx

EXPOSE 8080
