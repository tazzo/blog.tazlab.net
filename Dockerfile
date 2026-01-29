# Stage 1: Build static site
FROM hugomods/hugo:std AS builder
WORKDIR /src

# 1. Copy themes (Largest and least frequent change)
COPY themes/ themes/

# 2. Copy configuration and structural assets
COPY config/ config/
COPY assets/ assets/
COPY layouts/ layouts/
COPY archetypes/ archetypes/

# 3. Copy static files (images, etc)
COPY static/ static/

# 4. Copy content (Most frequent changes)
COPY content/ content/

# 5. Build the site
RUN hugo --minify

# Stage 2: Serve with Nginx Alpine
FROM nginx:stable-alpine
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
