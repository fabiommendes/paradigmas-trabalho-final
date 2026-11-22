import "./style.css";

import { Elm } from "./Main.elm";

const THEME_KEY = "ocaso-theme";
const savedTheme = localStorage.getItem(THEME_KEY);
const systemIsDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
const darkTheme = savedTheme ? savedTheme === "dark" : systemIsDark;

Elm.Main.init({
  node: document.getElementById("app"),
  flags: { darkTheme },
});

document.addEventListener("change", (event) => {
  if (event.target.matches(".theme-controller")) {
    localStorage.setItem(THEME_KEY, event.target.checked ? "dark" : "light");
  }
});
