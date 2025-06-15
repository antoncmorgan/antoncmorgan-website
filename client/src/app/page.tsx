import Head from 'next/head';
import styles from './home.module.css';
import ProjectCard from '../components/project-card';
import { Project } from '../types';

export default async function Home() {
  const res = await fetch('http://localhost:1337/api/projects?populate=*', { cache: 'no-store' });
  const data = await res.json();
  // Adapt to new structure: data.data is an array of Project objects
  const projects: Project[] = data.data;

  return (
    <>
      <Head>
        <title>Anton Morgan – Projects</title>
      </Head>
      <header className={styles.hero}>
        <div className={styles.heroText}>
          <p>A Passion to <span className={styles.code}>Code</span>.</p>
          <p>A Commitment to <span className={styles.design}>Design</span>.</p>
          <p>A Desire to <span className={styles.tinker}>Tinker</span>.</p>
        </div>
      </header>

      <main className={styles.main}>
        <h2 className={styles.sectionTitle}>Projects</h2>
        <p className={styles.sectionSubtitle}>A collection of personal projects</p>
        {projects.map(project => (
          <ProjectCard key={project.id} project={project} />
        ))}
      </main>

      <footer className={styles.footer}>
        <p>Anton Morgan</p>
        <p>Senior Designer<br />UX and Embedded Software<br />Age 33</p>
        <p>&copy; {new Date().getFullYear()} All Rights Reserved</p>
      </footer>
    </>
  );
}
