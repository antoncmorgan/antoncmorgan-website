"use client";
import styles from './Navbar.module.css';
import { useEffect, useRef } from 'react';

export default function Navbar() {
  const navRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const navbar = navRef.current;
    const hero = document.querySelector('.hero');
    function onScroll() {
      if (!navbar || !hero) return;
      const heroBottom = hero.getBoundingClientRect().bottom;
      // Add a 5vh buffer before triggering scrolled
      const buffer = window.innerHeight * 0.05;
      if (heroBottom <= buffer) {
        navbar.classList.add(styles.scrolled);
      } else {
        navbar.classList.remove(styles.scrolled);
      }
    }
    window.addEventListener('scroll', onScroll);
    onScroll();
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  return (
    <nav className={styles.navbar} ref={navRef}>
      <div className={styles.logo}>
        {/* SVG placeholder for logo/icon */}
        <svg width="32" height="32" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
          <rect width="32" height="32" rx="8" fill="#DFFB4A" />
        </svg>
      </div>
      <ul className={styles.navLinks}>
        <li>Personal</li>
        <li>Professional</li>
        <li>Blog</li>
      </ul>
      <div className={styles.socialIcons}>
        {/* Add GitHub/LinkedIn icons here */}
      </div>
    </nav>
  );
}
