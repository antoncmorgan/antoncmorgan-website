export interface Project {
    id: number;
    documentId: string;
    Title: string;
    Description: Array<{
        type: string;
        children: Array<{
            type: string;
            text: string;
        }>;
    }>;
    MainURL: string;
    CodeURL: string;
    createdAt: string;
    updatedAt: string;
    publishedAt: string;
    slug: string | null;
    Image: Array<{
        id: number;
        documentId: string;
        name: string;
        alternativeText: string | null;
        caption: string | null;
        width: number;
        height: number;
        formats: {
            thumbnail?: ImageFormat;
            small?: ImageFormat;
            medium?: ImageFormat;
            large?: ImageFormat;
        };
        hash: string;
        ext: string;
        mime: string;
        size: number;
        url: string;
        previewUrl: string | null;
        provider: string;
        provider_metadata: any;
        createdAt: string;
        updatedAt: string;
        publishedAt: string;
    }>;
    Icons: Array<{
        id: number;
        documentId: string;
        name: string;
        alternativeText: string | null;
        caption: string | null;
        width: number;
        height: number;
        formats: any;
        hash: string;
        ext: string;
        mime: string;
        size: number;
        url: string;
        previewUrl: string | null;
        provider: string;
        provider_metadata: any;
        createdAt: string;
        updatedAt: string;
        publishedAt: string;
    }>;
}

export interface ImageFormat {
    name: string;
    hash: string;
    ext: string;
    mime: string;
    path: string | null;
    width: number;
    height: number;
    size: number;
    sizeInBytes: number;
    url: string;
}
