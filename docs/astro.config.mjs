// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://foundry-agent-skillpack.example.com', // override at deploy time via SWA custom domain
  integrations: [
    starlight({
      title: 'Foundry Agent Skillpack',
      description:
        'End-to-end skillpack for Microsoft Foundry hosted agents — knowledge skills, slash commands, convergent lifecycle scripts, and durable per-agent state.',
      logo: {
        light: './src/assets/foundry-light.svg',
        dark: './src/assets/foundry-dark.svg',
        alt: 'Foundry Agent Skillpack',
        replacesTitle: false,
      },
      social: {
        github: 'https://github.com/sathik11/foundry-agent-skillpack',
      },
      editLink: {
        baseUrl:
          'https://github.com/sathik11/foundry-agent-skillpack/edit/main/docs/src/content/docs/',
      },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
        styleOverrides: { borderRadius: '0.5rem' },
      },
      pagefind: true,
      credits: false,
      sidebar: [
        {
          label: 'Start here',
          items: [
             { label: 'Home', link: '/' } ,
            { slug: 'getting-started/install' },
            { slug: 'getting-started/greenfield' },
            { slug: 'getting-started/brownfield' },
          ],
        },
        {
          label: 'Concepts',
          items: [
            { slug: 'concepts/what-is-this' },
            { slug: 'concepts/personas-and-roles' },
            { slug: 'concepts/capability-manifest' },
            { slug: 'concepts/agent-status' },
            { slug: 'concepts/lifecycle' },
            { slug: 'concepts/project-assessment' },
            { slug: 'concepts/convergent-scripts' },
            { slug: 'concepts/four-layer-guardrails' },
          ],
        },
        {
          label: 'Skills',
          items: [{ slug: 'skills' }],
        },
        {
          label: 'Recipes',
          autogenerate: { directory: 'recipes' },
        },
        {
          label: 'Reference',
          items: [
            { slug: 'reference/prompts' },
            { slug: 'reference/scripts' },
            { slug: 'reference/role-matrix' },
          ],
        },
        {
          label: 'Project',
          items: [
            { slug: 'roadmap' },
            { slug: 'contributing' },
            { slug: 'technical-debt' },
          ],
        },
      ],
    }),
  ],
});
