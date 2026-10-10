import styles from './home.module.css';
import ProjectCard from '../components/project-card';
import Navbar from '../components/Navbar';
import { getAllProjects, getSiteContent } from '../lib/content/projects';

export default function Home() {
  const projects = getAllProjects();
  const { heroImage } = getSiteContent();

  return (
    <>
      <Navbar />
      <header className={`${styles.hero} hero`} style={heroImage ? { backgroundImage: `url(${heroImage})` } : undefined}>
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
              <ProjectCard key={project.slug} project={project} index={idx} />
            ))}
          </div>
        </section>
      </main>
      <footer className={styles.footer}>
        <p>Anton Morgan</p>
        <p>Senior Software Engineer<br />UX and Embedded Software</p>
        <p>&copy; {new Date().getFullYear()} All Rights Reserved</p>
      </footer>
    </>
  );
}
