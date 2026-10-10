import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { projectSchema, siteSchema, type Project, type SiteContent } from './schema';

const contentDirectory = join(process.cwd(), 'content');
const projectsDirectory = join(contentDirectory, 'projects');

function parseJsonFile(filePath: string): unknown {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to parse content file ${filePath}`, { cause: error });
  }
}

export function getAllProjects(): Project[] {
  return readdirSync(projectsDirectory)
    .filter((fileName) => fileName.endsWith('.json'))
    .sort()
    .map((fileName) => projectSchema.parse(parseJsonFile(join(projectsDirectory, fileName))));
}

export function getProjectBySlug(slug: string): Project | undefined {
  return getAllProjects().find((project) => project.slug === slug);
}

export function getFeaturedProjects(): Project[] {
  return getAllProjects().filter((project) => project.featured);
}

export function getSiteContent(): SiteContent {
  return siteSchema.parse(parseJsonFile(join(contentDirectory, 'site.json')));
}
