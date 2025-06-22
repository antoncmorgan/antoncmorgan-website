import React from 'react';
import styles from './project-card.module.css';
import { Project } from '../types';

interface Props {
  project: Project;
  index?: number; // To alternate layout
}

const ProjectCard = ({ project, index = 0 }: Props) => {
  const mainImage = project.Image?.[0];
  const imageUrl = mainImage?.formats?.medium?.url || mainImage?.url;
  const icons = project.Icons || [];
  // Alternate layout for even/odd cards
  const isEven = index % 2 === 1;

  return (
    <div className={
      isEven ? `${styles.projectCard} ${styles.reverse}` : styles.projectCard
    }>
      <div className={styles.projectImage}>
        {imageUrl && (
          <img
            src={imageUrl.startsWith('http') ? imageUrl : `http://localhost:1337${imageUrl}`}
            alt={mainImage?.name || project.Title}
            className={styles.tiltedImage}
          />
        )}
      </div>
      <div className={styles.projectContent}>
        <h3 className={styles.projectTitle}>{project.Title}</h3>
        {project.Description?.map((block, i) => (
          <p key={i} className={styles.projectDescription}>
            {block.children?.map((child, j) => child.text).join(' ')}
          </p>
        ))}
        <div className={styles.techIcons}>
          {icons.map(icon => (
            <img
              key={icon.id}
              src={icon.url.startsWith('http') ? icon.url : `http://localhost:1337${icon.url}`}
              alt={icon.name}
              width={32}
              height={32}
            />
          ))}
        </div>
        <div className={styles.buttonRow}>
          {project.MainURL && (
            <a className={`${styles.button} ${styles.primaryButton}`} href={project.MainURL} target="_blank" rel="noreferrer">
              Go To Project
            </a>
          )}
          {project.CodeURL && (
            <a className={styles.button} href={project.CodeURL} target="_blank" rel="noreferrer">
              Source Code
            </a>
          )}
        </div>
      </div>
    </div>
  );
};

export default ProjectCard;
