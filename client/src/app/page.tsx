import Head from 'next/head';
import styles from './home.module.css';
import ProjectCard from '../components/project-card';
import { Project } from '../types';
import Navbar from '../components/Navbar';

export default async function Home() {
  // Fetch projects
  const res = await fetch('http://localhost:1337/api/projects?populate=*', { cache: 'no-store' });
  const data = await res.json();
  const projects: Project[] = data.data;

  // Fetch hero image
  const heroRes = await fetch('http://localhost:1337/api/heroes?populate=*', { cache: 'no-store' });
  const heroData = await heroRes.json();
  // Updated extraction for hero image based on provided object structure
  const heroImageData = heroData?.data?.[0]?.heroImage?.[0];
  const heroImageUrl = heroImageData?.formats?.medium?.url || heroImageData?.url || '';
  const heroImageFullUrl = heroImageUrl && !heroImageUrl.startsWith('http') ? `http://localhost:1337${heroImageUrl}` : heroImageUrl;

  return (
    <>
      <Head>
        <title>Anton Morgan – Projects</title>
        {/* Google Fonts: Montserrat for headings/nav, Open Sans for body */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@400;700&family=Open+Sans:wght@400;600&display=swap" rel="stylesheet" />
      </Head>
      {/* Navigation Bar */}
      <Navbar />
      {/* Hero Section with dynamic background image */}
      <header className={styles.hero + ' hero'} style={heroImageFullUrl ? { backgroundImage: `url(${heroImageFullUrl})` } : {}}>
        <div className={styles.heroOverlay}></div>
        <div className={styles.heroText}>
          <p>A Passion to <span className={styles.code}>Code</span>.</p>
          <p>A Commitment to <span className={styles.design}>Design</span>.</p>
          <p>A Desire to <span className={styles.tinker}>Tinker</span>.</p>
        </div>
      </header>
      <main className={styles.main}>
        <section className={styles.projectsSection}>
          <h2 className={styles.sectionTitle}>Projects</h2>
          <p className={styles.sectionSubtitle}>A collection of personal projects</p>
          <div className={styles.projectsList}>
            {projects.map((project, idx) => (
              <ProjectCard key={project.id} project={project} layout={idx % 2 === 0 ? 'left' : 'right'} />
            ))}
          </div>
        </section>
      </main>
      <footer className={styles.footer}>
        <p>Anton Morgan</p>
        <p>Senior Designer<br />UX and Embedded Software<br />Age 33</p>
        <p>&copy; {new Date().getFullYear()} All Rights Reserved</p>
      </footer>
    </>
  );
}
