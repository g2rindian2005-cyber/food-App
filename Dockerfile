# ─────────────────────────────────────────
# Stage 1: Build
# Minifies HTML/CSS/JS using Node.js tools
# ─────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy all source files
COPY . .

# Install minification tools
RUN npm install -g \
    html-minifier-terser \
    clean-css-cli \
    terser

# Minify HTML files
RUN mkdir -p dist/pages && \
    html-minifier-terser \
      --collapse-whitespace \
      --remove-comments \
      --remove-redundant-attributes \
      --use-short-doctype \
      --minify-js true \
      --minify-css true \
      index.html -o dist/index.html && \
    for f in pages/*.html; do \
      html-minifier-terser \
        --collapse-whitespace \
        --remove-comments \
        --remove-redundant-attributes \
        --use-short-doctype \
        --minify-js true \
        --minify-css true \
        "$f" -o "dist/pages/$(basename $f)"; \
    done

# Minify CSS files
RUN mkdir -p dist/css && \
    for f in css/*.css; do \
      cleancss -o "dist/css/$(basename $f)" "$f"; \
    done

# Minify JS files
RUN mkdir -p dist/js dist/data && \
    for f in js/*.js; do \
      terser "$f" -o "dist/js/$(basename $f)" --compress --mangle; \
    done && \
    cp data/*.js dist/data/

# Copy assets (icons, images, etc.)
RUN if [ -d "assets" ] && [ "$(ls -A assets 2>/dev/null)" ]; then \
      cp -r assets dist/assets; \
    fi

# ─────────────────────────────────────────
# Stage 2: Serve
# Lightweight Nginx image — only serves files
# Final image has NO Node.js, NO build tools
# ─────────────────────────────────────────
FROM nginx:1.27-alpine

# Remove default Nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy minified build output from builder stage
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy custom Nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Expose port 80
EXPOSE 80

# Health check — verify Nginx is serving
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
