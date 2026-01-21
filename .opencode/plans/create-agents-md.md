# Plan: Create AGENTS.md File for Hugo Blog Repository

## Overview
I will create a comprehensive AGENTS.md file for this Hugo blog repository that provides essential development guidelines for agentic coding agents.

## Analysis Summary

Based on my exploration of the codebase, this is a **Hugo static site blog** using the **Blowfish theme** (v2.96.0) with the following key characteristics:

### Technology Stack
- **Hugo** - Static Site Generator
- **Blowfish Theme** - Git submodule with Tailwind CSS
- **Node.js** - Build tooling for theme assets
- **ImageMagick** - Image processing scripts
- **Multilingual support** (English/Italian)

### Project Structure
- `config/_default/` - Hugo configuration files (TOML format)
- `content/` - Blog posts and guides with multilingual structure
- `assets/css/custom.css` - Custom CSS overrides
- `layouts/partials/` - Template customizations
- `themes/blowfish/` - Theme as Git submodule
- Image processing scripts in `content/`

### Build System
- Hugo commands for site generation
- Theme uses Node.js with npm scripts for CSS compilation
- ImageMagick scripts for image optimization
- No root package.json - uses theme's build system

### Coding Conventions
- TOML front matter for content
- Go template syntax for HTML
- Tailwind CSS with custom overrides
- Prettier formatting (2-space indent, double quotes)
- Multilingual file naming (index.md / index.it.md)

## AGENTS.md Content Plan

I will create a ~150-line AGENTS.md file with the following sections:

### 1. Project Overview & Technology Stack
- Brief description of the Hugo blog
- Key technologies and their versions
- Theme information (Blowfish v2.96.0)

### 2. Build & Development Commands
- Hugo commands (server, build, clean)
- Theme asset commands (npm scripts from themes/blowfish/)
- Image processing scripts
- Development workflow commands

### 3. Project Structure
- Directory tree with explanations
- Key files and their purposes
- Multilingual content organization

### 4. Code Style Guidelines
- Front matter format (TOML)
- Content structure and naming
- CSS customization approach
- HTML template patterns
- JavaScript handling

### 5. Formatting & Linting
- Prettier configuration from theme
- File-specific formatting rules
- EditorConfig settings

### 6. Development Workflow
- Creating new content process
- Multilingual content guidelines
- Customization approach
- Theme update process

### 7. Testing & Quality Assurance
- Content testing commands
- Image optimization requirements
- Link validation

### 8. Common Tasks
- Adding new blog posts (step-by-step)
- Updating theme configuration
- Custom CSS changes

### 9. Deployment & Performance
- Build process
- Environment variables
- Security considerations
- Performance optimization

### 10. Troubleshooting
- Common issues and solutions
- Debug commands
- Support resources

## Key Information to Include

### Build Commands
```bash
# Hugo (from root)
hugo server -D --bind 0.0.0.0 --port 1313
hugo --minify

# Theme assets (from themes/blowfish/)
npm run dev
npm run build
npm run assets

# Image processing (from content/)
./png2jpg.sh
./jpg-600x600.sh
```

### Code Style
- TOML front matter with specific field structure
- 2-space indentation, double quotes, semicolons
- Tailwind CSS with custom overrides
- Go template syntax for HTML

### File Structure
- Content: `content/posts/article-name/index.md`
- Multilingual: `index.md` (EN), `index.it.md` (IT)
- Custom CSS: `assets/css/custom.css`
- Config: `config/_default/*.toml`

### Development Patterns
- Minimal theme overrides
- Configuration-driven theming
- Image optimization workflow
- Multilingual content consistency

## Implementation Notes

- The file will be approximately 150 lines as requested
- No existing AGENTS.md file to improve
- No Cursor/Copilot rules found to include
- Focus on practical, actionable information
- Include specific commands and examples
- Address the Hugo + Blowfish theme combination

## Next Steps

Once approved, I will:
1. Create the AGENTS.md file with the outlined structure
2. Include all relevant build commands and coding standards
3. Ensure the content is accurate based on the codebase analysis
4. Format it properly for readability by agentic coding agents