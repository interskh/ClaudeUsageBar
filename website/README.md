# ClaudeUsageBar Website

Landing page for ClaudeUsageBar macOS app.

## Structure

```
website/
└── index.html    - Single-page landing site with inline CSS
```

## Deployment

### GitHub Pages

This website can be deployed to GitHub Pages:

1. Go to repository Settings → Pages
2. Source: Deploy from branch
3. Branch: `main`
4. Folder: `/website`
5. Save

Pages is not set up for this fork. If you enable it on
[interskh/ClaudeUsageBar](https://github.com/interskh/ClaudeUsageBar), the site would be
served from `https://interskh.github.io/ClaudeUsageBar/`.

**Note:** `claudeusagebar.com` is the original project's custom domain (via Vercel) and
serves its site, not this one.

### Local Development

Simply open `index.html` in a browser:

```bash
open index.html
```

Or use a local server:

```bash
python3 -m http.server 8000
# Visit http://localhost:8000
```

## Technologies

- Pure HTML5
- Inline CSS (no external dependencies)
- Responsive design
- Dark theme
- Inter font from Google Fonts

## Features

- Hero section with build-from-source CTA
- Feature showcase
- Build instructions
- Screenshots section
- FAQ
- Footer with links

## Customization

All styles are inline in `index.html`. To customize:

1. Edit colors in CSS variables at top of `<style>` section
2. Update content in HTML sections
3. Replace links with your GitHub username/repo

## Future Enhancements

- [ ] Extract CSS to separate file (`assets/css/style.css`)
- [ ] Add images folder (`assets/images/`)
- [ ] Add JavaScript for animations
- [ ] Add analytics (optional)
- [ ] Add blog/changelog section
