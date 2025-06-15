import React from 'react';
import styles from '../app/home.module.css';
import { Project } from '../types';

interface Props {
  project: Project;
}

const ProjectCard = ({ project }: Props) => {
  // Adapt to new structure
  const mainImage = project.Image?.[0];
  const imageUrl = mainImage?.formats?.medium?.url || mainImage?.url;
  const icons = project.Icons || [];
  return (
    <div className={styles.projectCard}>
      <div className={styles.projectImage}>
        {imageUrl && (
          <img src={imageUrl.startsWith('http') ? imageUrl : `http://localhost:1337${imageUrl}`} alt={mainImage?.name || project.Title} />
        )}
      </div>
      <div className={styles.projectContent}>
        <h3>{project.Title}</h3>
        {/* Render rich description */}
        {project.Description?.map((block, i) => (
          <p key={i}>{block.children?.map((child, j) => child.text).join(' ')}</p>
        ))}
        <div className={styles.techIcons}>
          {icons.map(icon => (
            <img
              key={icon.id}
              src={icon.url.startsWith('http') ? icon.url : `http://localhost:1337${icon.url}`}
              alt={icon.name}
              width={24}
              height={24}
              style={{ marginRight: 8 }}
            />
          ))}
        </div>
        {project.MainURL && (
          <a className={styles.button} href={project.MainURL} target="_blank" rel="noreferrer">Go To Project</a>
        )}
        {project.CodeURL && (
          <a className={styles.sourceLink} href={project.CodeURL} target="_blank" rel="noreferrer">Source Code</a>
        )}
      </div>
    </div>
  );
};

export default ProjectCard;
