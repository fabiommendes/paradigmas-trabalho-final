// Configuração do Vite: servidor de desenvolvimento com hot reload.
import { defineConfig } from "vite";
import elm from "vite-plugin-elm"; // compila arquivos .elm importados no JS
import tailwindcss from "@tailwindcss/vite"; // gera o CSS do Tailwind/daisyUI

export default defineConfig({
  plugins: [elm(), tailwindcss()],
  server: {
    // Toda requisição para /api/... é repassada ao backend FastAPI. Assim o
    // frontend e o backend parecem estar no mesmo endereço, e não precisamos
    // configurar CORS.
    proxy: {
      "/api": "http://localhost:8000",
    },
  },
});
