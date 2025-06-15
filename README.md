# antoncmorgan-website

This website showcases and links to my personal work, including projects, blog posts, and other creative endeavors. It consists of two main parts:

- A Next.js frontend (in the `client/` folder) for the public-facing website.
- A Strapi backend (in the `strapi/` folder) for managing content such as projects and blog posts.

## Purpose

The goal of this website is to provide a central hub for my portfolio, allowing visitors to explore my work and learn more about my skills and experience. The backend (Strapi) makes it easy to add and update content without modifying the frontend code.

## How to Run the Project

### 1. Start the Strapi Backend

1. Run the following:
   ```
   cd strapi
   npm install
   npm run develop
   ```
   The Strapi admin panel will be available (usually at http://localhost:1337).

### 2. Start the Next.js Frontend

1. 
   ```
   cd client
   npm install
   npm run dev
   ```
   The website will be available at http://localhost:3000.

### 3. Access the Website

- Visit http://localhost:3000 to view the frontend.
- Visit http://localhost:1337/admin to manage content in Strapi.

## Deployment

- TBD