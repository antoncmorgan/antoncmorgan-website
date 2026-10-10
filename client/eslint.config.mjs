import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['.next/**', 'out/**'],
  },
  eslint.configs.recommended,
  tseslint.configs.recommended,
);
