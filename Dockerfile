# Stage 1: Build static site
FROM hugomods/hugo:std AS builder
WORKDIR /src
COPY . .
RUN hugo --minify

# Stage 2: Serve with Nginx
FROM nginx:stable-alpine
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
