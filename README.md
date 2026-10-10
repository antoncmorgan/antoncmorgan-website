# antoncmorgan-website

This website showcases personal projects as a static Next.js site. Content is stored in Git as JSON, so it has no CMS, database, API server, or runtime environment variables.

## Local development

```bash
cd client
npm ci
npm run dev
```

Visit <http://localhost:3000>. `npm run build` validates all content and produces the static export.

## Content

- Project files live in [`client/content/projects`](client/content/projects), with one JSON file per project.
- Site-wide content lives in [`client/content/site.json`](client/content/site.json).
- Project media lives in [`client/public/images/projects/<project-slug>`](client/public/images/projects).
- [`client/src/lib/content/schema.ts`](client/src/lib/content/schema.ts) defines the Zod-validated project schema, and [`client/src/lib/content/projects.ts`](client/src/lib/content/projects.ts) is the only content access layer used by the UI.

Add a project by copying this minimal shape into `client/content/projects/<slug>.json`, adding its media under the matching public-images directory, then running `npm run build`:

```json
{
  "slug": "example-project",
  "title": "Example Project",
  "description": ["A concise description."],
  "image": {
    "src": "/images/projects/example-project/cover.webp",
    "alt": "Example Project",
    "width": 1200,
    "height": 675
  },
  "icons": [],
  "mainUrl": null,
  "codeUrl": null
}
```

Edit an existing project by changing its JSON and local media. `featured` is optional and may be set to `true` for consumers of `getFeaturedProjects()`.

Only the repository-tracked Archery Challenge image and icons were available to migrate. Its description, links, any additional projects, and the previous hero image were not present in Git or reachable from the configured Strapi endpoint, so they need to be copied from the former CMS into JSON and `public/images` before the CMS is decommissioned.

## Deployment

Connect the repository's `main` branch to AWS Amplify Hosting with `client` as the application root. Each push to `main` causes Amplify to build and publish the static site; no AWS database, container, or runtime backend is required.