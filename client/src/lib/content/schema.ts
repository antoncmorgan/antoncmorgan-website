import { z } from 'zod';

const localAssetPath = z.string().regex(/^\/images\//, 'must reference an image in public/images');
const optionalUrl = z.string().url().nullable();

export const projectSchema = z.object({
  slug: z.string().regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, 'must be a lowercase URL slug'),
  title: z.string().min(1),
  description: z.array(z.string().min(1)),
  image: z.object({
    src: localAssetPath,
    alt: z.string().min(1),
    width: z.number().int().positive(),
    height: z.number().int().positive(),
  }),
  icons: z.array(z.object({
    src: localAssetPath,
    alt: z.string().min(1),
  })),
  mainUrl: optionalUrl,
  codeUrl: optionalUrl,
  featured: z.boolean().optional(),
}).strict();

export const siteSchema = z.object({
  heroImage: localAssetPath.nullable(),
}).strict();

export type Project = z.infer<typeof projectSchema>;
export type SiteContent = z.infer<typeof siteSchema>;
