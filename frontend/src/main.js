import "./style.css";

import { Elm } from "./Main.elm";

const THEME_KEY = "ocaso-theme";
// em aba anônima ou com cookies bloqueados, o localStorage lança exceção
// sem a proteção, o Elm nem chegaria a iniciar
let savedTheme = null;
try {
  savedTheme = localStorage.getItem(THEME_KEY);
} catch {
  // Sem armazenamento: usa o tema do sistema.
}
const systemIsDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
const darkTheme = savedTheme ? savedTheme === "dark" : systemIsDark;

Elm.Main.init({
  node: document.getElementById("app"),
  flags: { darkTheme },
});

document.addEventListener("change", (event) => {
  if (event.target.matches(".theme-controller")) {
    try {
      localStorage.setItem(THEME_KEY, event.target.checked ? "dark" : "light");
    } catch {
      // sem armazenamento: o tema só não fica salvo para a próxima visita
    }
  }
});
