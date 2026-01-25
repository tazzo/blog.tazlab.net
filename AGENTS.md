# AGENTS.md

This file contains guidelines and commands for agentic coding agents working in this Hugo blog repository.

## Project Overview

This is a Hugo static site blog using the Blowfish theme, focused on DevOps, Kubernetes, and infrastructure topics. The site supports bilingual content (English/Italian) and is deployed on Kubernetes.

## Build and Development Commands

### Hugo Commands (Primary)
```bash
# Development server with drafts and future content
hugo server -D --buildDrafts --buildFuture --watch

# Production build (minified)
hugo --minify

# Build specific content section
hugo --contentDir content/posts

# Clean build (remove public/ first)
rm -rf public/ && hugo --minify
```

### Theme Asset Commands
```bash
# Install theme dependencies
cd themes/blowfish && npm install

# Development CSS build (watch mode)
cd themes/blowfish && npm run dev

# Production CSS build
cd themes/blowfish && npm run build

# Copy vendor assets
cd themes/blowfish && npm run assets
```

### Testing and Validation
```bash
# Validate Hugo configuration
hugo config

# Check for broken links (if hugo-extended is available)
hugo server --buildDrafts --navigateToChanged

# Test build without publishing
hugo --buildDrafts --buildFuture --destination /tmp/test-build
```

## Code Style Guidelines

### Markdown Content
- **Front matter**: Use TOML format with `+++` delimiters
- **Required fields**: `title`, `date`, `draft`, `description`, `tags`, `author`
- **File naming**: 
  - English: `index.md`
  - Italian: `index.it.md`
  - Post directories: kebab-case (e.g., `talos-linux-tailscale-guide`)
- **Image naming**: Use `featured.jpg` for post thumbnails
- **Tags**: Lowercase, technical terms (kubernetes, talos, devops, etc.)

### Formatting Standards
- **Indentation**: 2 spaces (no tabs)
- **Line endings**: LF
- **Encoding**: UTF-8
- **Trailing whitespace**: Trimmed (except in .md files where it may be intentional)
- **Final newlines**: Required
- **Quotes**: Double quotes for JSON/YAML, single for JavaScript/TypeScript

### Content Structure
- **Posts**: Technical tutorials and implementation guides
- **Guides**: Comprehensive documentation on specific technologies
- **Bilingual**: Maintain both English and Italian versions when possible
- **Code blocks**: Use proper syntax highlighting with language specified
- **YAML configs**: Include complete, copy-paste ready configuration examples

## File Organization

### Content Structure
```
content/
├── posts/          # Technical blog posts
├── guides/         # Comprehensive guides
└── _index.md       # Homepage content
```

### Theme Assets
```
themes/blowfish/
├── assets/         # CSS, JS, images
├── layouts/        # Template files
├── config.toml     # Theme configuration
└── package.json    # Node.js dependencies
```

## Working with This Repository

### When Adding New Content
1. Create appropriate directory under `content/posts/` or `content/guides/`
2. Add `index.md` with proper TOML front matter
3. If supporting Italian, add `index.it.md`
4. Include `featured.jpg` image if possible
5. Test with `hugo server -D` before committing

### When Modifying Theme
1. Navigate to `themes/blowfish/`
2. Install dependencies with `npm install`
3. Use `npm run dev` for development
4. Use `npm run build` for production
5. Run `npm run assets` to update vendor dependencies

### When Making Configuration Changes
1. Primary config: `config/_default/hugo.toml` and `params.toml`
2. Theme config: `themes/blowfish/config.toml`
3. Test changes with `hugo config` to validate syntax
4. Restart development server to see changes

## Common Tasks

### Adding a New Blog Post
```bash
# Create directory
mkdir -p content/posts/your-post-title

# Create English content
cat > content/posts/your-post-title/index.md << 'EOF'
+++
title = "Your Post Title"
date = 2026-01-22
draft = true
description = "Brief description of the post"
tags = ["kubernetes", "devops"]
author = "Tazzo"
+++

# Your post content here...
EOF
```

### Updating Theme Assets
```bash
cd themes/blowfish
npm install
npm run build
cd ../..
hugo --minify
```

### Validating Site Build
```bash
# Test build
hugo --buildDrafts --buildFuture --destination /tmp/test-build

# Check for errors
echo $?  # Should return 0
```

## Deployment Notes

- The site is deployed on Kubernetes using git-sync for content updates
- Longhorn provides persistent storage
- Domain: blog.tazlab.net
- Use `hugo --minify` for production builds

## Language Support

- Primary language: English
- Secondary language: Italian
- Use `.it.md` suffix for Italian content
- Maintain consistent metadata across language versions

## Security Considerations

- Never commit secrets or API keys
- Use environment variables for sensitive configuration
- Validate all user-provided content in code examples
- Keep Hugo and theme dependencies updated