// Ponto de entrada JavaScript. O Vite começa por aqui (veja index.html).
// Escolha UM dos dois estilos (as classes são as mesmas nos dois):
//   style.css          visual completo: temas próprios, fontes, gradientes,
//                      animações e várias técnicas de CSS moderno
//   style-simples.css  visual minimalista, quase só com @apply do Tailwind;
//                      um ponto de partida mais fácil de entender e modificar
import "./style.css";
// import "./style-simples.css";

// O vite-plugin-elm permite importar um módulo Elm como se fosse JS: ele
// compila src/Main.elm e recompila a cada alteração (hot reload).
import { Elm } from "./Main.elm";

// Tema inicial: a última escolha do jogador (guardada no localStorage do
// navegador) ou, na primeira visita, a preferência do sistema operacional.
const THEME_KEY = "sudoku-theme";
const savedTheme = localStorage.getItem(THEME_KEY);
const systemIsDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
const darkTheme = savedTheme ? savedTheme === "dark" : systemIsDark;

// `flags` é entregue à função `init` do Elm (veja o tipo Flags em Main.elm).
Elm.Main.init({
  node: document.getElementById("app"),
  flags: { darkTheme },
});

// Guarda a escolha quando o botão de tema muda. Ouvimos o evento no
// `document` inteiro ("delegação de eventos") porque o checkbox é criado pelo
// Elm e pode ser recriado a qualquer momento.
//
// Isto poderia ser feito com uma PORT do Elm (um canal de mensagens entre Elm
// e JavaScript), mas para algo tão simples o JavaScript sozinho basta.
document.addEventListener("change", (event) => {
  if (event.target.matches(".theme-controller")) {
    localStorage.setItem(THEME_KEY, event.target.checked ? "dark" : "light");
  }
});
