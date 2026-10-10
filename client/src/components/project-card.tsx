import React from 'react';
import Image from 'next/image';
import styles from './project-card.module.css';
import type { Project } from '../lib/content/schema';

interface Props {
  project: Project;
  index?: number;
}

const ProjectCard = ({ project, index = 0 }: Props) => {
  const isEven = index % 2 === 1;

  return (
    <div className={
      isEven ? `${styles.projectCard} ${styles.reverse}` : styles.projectCard
    }>
      <div className={styles.projectImage}>
        <Image
          src={project.image.src}
          alt={project.image.alt}
          width={project.image.width}
          height={project.image.height}
          className={styles.tiltedImage}
        />
      </div>
      <div className={styles.projectContent}>
        <h3 className={styles.projectTitle}>{project.title}</h3>
        {project.description.map((paragraph, i) => (
          <p key={i} className={styles.projectDescription}>
            {paragraph}
          </p>
        ))}
        <div className={styles.techIcons}>
          {project.icons.map((icon) => (
            <Image
              key={icon.src}
              src={icon.src}
              alt={icon.alt}
              width={32}
              height={32}
            />
          ))}
        </div>
        <div className={styles.buttonRow}>
          {project.mainUrl && (
            <a className={`${styles.button} ${styles.primaryButton}`} href={project.mainUrl} target="_blank" rel="noreferrer">
              Go To Project
            </a>
          )}
          {project.codeUrl && (
            <a className={styles.button} href={project.codeUrl} target="_blank" rel="noreferrer">
              Source Code
            </a>
          )}
        </div>
      </div>
    </div>
  );
};

export default ProjectCard;
