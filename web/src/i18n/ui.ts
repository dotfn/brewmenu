export const languages = {
  en: "English",
  es: "Español",
} as const;

export const defaultLang = "en";

export const ui = {
  en: {
    "meta.title": "BrewMenu: Homebrew, actually visible",
    "meta.description":
      "A native macOS menu bar app for Homebrew: see updates, doctor warnings, cleanups, and services at a glance, without touching the terminal.",
    "meta.ogImageAlt": "BrewMenu: a native macOS menu bar app for Homebrew",

    "sidebar.search": "Search formulae & casks",
    "sidebar.nav.overview": "Overview",
    "sidebar.nav.screenshots": "Screenshots",
    "sidebar.nav.features": "Features",
    "sidebar.nav.install": "Install",
    "sidebar.nav.faq": "FAQ",
    "sidebar.elsewhere": "Elsewhere",
    "sidebar.elsewhere.site": "dotfn.dev",
    "sidebar.themeToggle": "Toggle dark/light theme",
    "sidebar.languageToggle": "Switch to Spanish",

    "hero.tagline": "You Homebrew, actually visible.",
    "hero.valueProp": "Homebrew, without the terminal.",
    "hero.valuePropBody":
      "BrewMenu lives in your menu bar, keeps an eye on your packages, and lets you update everything with one click.",
    "hero.onlyForMac": "Only for Mac",
    "hero.free": "Free",
    "hero.get": "GET",
    "hero.share": "Copy link to this page",

    "info.price": "Price",
    "info.category": "Category",
    "info.developer": "Developer",
    "info.language": "Language",
    "info.size": "Size",
    "info.category.value": "Developer Tools",
    "info.language.value": "EN + ES",

    "screenshots.tab": "Mac",
    "screenshots.alt.home":
      "The BrewMenu Dashboard's Home view, showing installed package counts, trending Homebrew formulae, recommended packages, and install packs",
    "screenshots.alt.menuBar":
      "The BrewMenu popover open from the menu bar, showing an insight about accumulated updates, running services, and a list of outdated packages with an Upgrade All button",
    "screenshots.alt.outdated":
      "The BrewMenu Dashboard's Outdated Packages view, listing packages with individual Update buttons and an Upgrade All button",
    "screenshots.alt.installed":
      "The BrewMenu Dashboard's Installed view, listing all installed formulae and casks with their versions",
    "screenshots.alt.cask":
      "The BrewMenu Dashboard's Cask view, listing installed cask apps like Brave, Firefox, and Visual Studio Code with their versions",
    "screenshots.alt.ecosystems":
      "The BrewMenu Dashboard's Ecosystems Overview, grouping installed packages by tap: dotfn/tap, Cask, Core, and third-party taps",
    "screenshots.alt.recommendedTaps":
      "The BrewMenu Dashboard's Recommended Taps view, showing curated third-party taps like HashiCorp, yabai & skhd, and 1Password CLI with Add Tap buttons",
    "screenshots.alt.thirdParty":
      "The BrewMenu Dashboard's Third-Party view, listing packages from custom taps such as dotfn/tap and productdevbook/tap",
    "screenshots.alt.settings":
      "The BrewMenu Dashboard's General settings view, with toggles for login, update count, menu bar icon behavior, and check frequency",
    "screenshots.lightbox.close": "Close",
    "screenshots.lightbox.prev": "Previous screenshot",
    "screenshots.lightbox.next": "Next screenshot",

    "description.heading": "What it does",
    "description.intro":
      "BrewMenu layers a visual interface on top of the Homebrew you already have installed — it doesn't replace it, and the brew CLI keeps working exactly as before.",
    "description.cap1": "Lives in the menu bar, one click away at all times",
    "description.cap2": "Flags outdated packages with a badge and native notifications",
    "description.cap3": "Updates packages one at a time or all at once",
    "description.cap4": "Searches and installs formulae and casks",
    "description.cap5": "Surfaces brew doctor warnings inline",
    "description.cap6": "Starts, stops, and monitors background services",
    "description.cap7": "Includes a full Dashboard for browsing everything installed",
    "description.closing": "Native SwiftUI. No Electron, no background daemon quietly draining your battery.",

    "ratings.heading": "Ratings & Reviews",
    "ratings.doesNotCollect": "BrewMenu doesn't collect ratings.",
    "ratings.withStars": "The closest thing is GitHub — {stars} stars so far.",
    "ratings.withoutStars": "The closest thing is a star on GitHub.",
    "ratings.cta": "Leave one →",

    "privacy.heading": "App Privacy",
    "privacy.intro": "dotfn does not collect any data from this app.",
    "privacy.sourceLink": "See the source on GitHub",
    "privacy.dataNotCollected": "Data Not Collected",
    "privacy.dataNotCollectedBody":
      "BrewMenu reads and manages your local Homebrew Cellar only. It doesn't access the rest of your Mac or send anything to a server.",

    "accessibility.heading": "Accessibility",
    "accessibility.body":
      "Built with native SwiftUI controls, so VoiceOver, Dynamic Type, and Reduce Motion follow your system settings by default.",

    "infoGrid.heading": "Information",
    "infoGrid.seller": "Seller",
    "infoGrid.size": "Size",
    "infoGrid.category": "Category",
    "infoGrid.compatibility": "Compatibility",
    "infoGrid.compatibility.value": "Requires macOS 15.0 or later",
    "infoGrid.languages": "Languages",
    "infoGrid.languages.value": "English, Español",
    "infoGrid.price": "Price",
    "infoGrid.version": "Version",
    "infoGrid.copyright": "Copyright",
    "infoGrid.copyright.value": "© 2026 dotfn",
    "infoGrid.developerWebsite": "Developer Website",
    "infoGrid.sourceCode": "Source Code",

    "supports.heading": "Supports",
    "supports.openSource": "Open Source",
    "supports.openSourceBody": "MIT licensed and public on GitHub — read the code, file an issue, or send a PR.",

    "install.heading": "Two minutes to install.",
    "install.subheading": "One command to remove, nothing left behind.",
    "install.window1Title": "Install BrewMenu",
    "install.window2Title": "Install Homebrew + BrewMenu",
    "install.uninstallPrefix": "Uninstall anytime with",
    "install.noBrew": "New Mac, no Homebrew yet? This one-liner installs both.",
    "install.copy": "Copy",
    "install.copied": "Copied!",

    "faq.heading": "Questions",
    "faq.q1": "Is BrewMenu free?",
    "faq.a1": "Yes. BrewMenu is free and open source under the MIT license, no account or sign-up required.",
    "faq.q2": "Does it replace the brew CLI?",
    "faq.a2":
      "No. BrewMenu reads and manages your existing Homebrew Cellar, it's a visible layer on top of brew, not a replacement for it. The CLI still works exactly as before.",
    "faq.q3": "What macOS versions does it support?",
    "faq.a3": "macOS 15 (Sequoia) and later. Older systems aren't supported yet.",
    "faq.q4": "Is my data sent anywhere?",
    "faq.a4":
      "No. BrewMenu only reads and manages your local Homebrew Cellar. It doesn't have access to the rest of your Mac and doesn't send data to a server.",

    "moreBy.heading": "More by dotfn",
    "moreBy.site": "dotfn.dev",
    "moreBy.siteBody": "Studio site & other builds",
    "moreBy.github": "GitHub",
    "moreBy.githubBody": "Source code & other repos",
    "moreBy.x": "X / Twitter",
    "moreBy.xBody": "Build-in-public updates",
    "moreBy.view": "View",

    "footer.copyright": "Copyright © 2026 dotfn. All rights reserved.",
    "footer.github": "GitHub",
    "footer.releases": "Releases",
    "footer.license": "MIT License",
  },
  es: {
    "meta.title": "BrewMenu: Homebrew, por fin visible",
    "meta.description":
      "Una app nativa de macOS que vive en la barra de menú y te muestra lo que Homebrew nunca te dice: updates, warnings de doctor, limpiezas y servicios, de un vistazo, sin tocar la terminal.",
    "meta.ogImageAlt": "BrewMenu: una app nativa de macOS para Homebrew en la barra de menú",

    "sidebar.search": "Buscar formulae y casks",
    "sidebar.nav.overview": "Resumen",
    "sidebar.nav.screenshots": "Capturas",
    "sidebar.nav.features": "Funciones",
    "sidebar.nav.install": "Instalar",
    "sidebar.nav.faq": "Preguntas",
    "sidebar.elsewhere": "En otro lado",
    "sidebar.elsewhere.site": "dotfn.dev",
    "sidebar.themeToggle": "Cambiar tema claro/oscuro",
    "sidebar.languageToggle": "Switch to English",

    "hero.tagline": "Tu Homebrew, por fin visible.",
    "hero.valueProp": "Homebrew, sin la terminal.",
    "hero.valuePropBody": "BrewMenu vive en tu barra de menú, vigila tus paquetes y te deja actualizar todo con un clic.",
    "hero.onlyForMac": "Solo para Mac",
    "hero.free": "Gratis",
    "hero.get": "OBTENER",
    "hero.share": "Copiar el link de esta página",

    "info.price": "Precio",
    "info.category": "Categoría",
    "info.developer": "Desarrollador",
    "info.language": "Idioma",
    "info.size": "Tamaño",
    "info.category.value": "Herramientas dev",
    "info.language.value": "EN + ES",

    "screenshots.tab": "Mac",
    "screenshots.alt.home":
      "La vista Home del Dashboard de BrewMenu, mostrando la cantidad de paquetes instalados, fórmulas trending de Homebrew, paquetes recomendados e install packs",
    "screenshots.alt.menuBar":
      "El popover de BrewMenu abierto desde la barra de menú, mostrando un insight sobre updates acumulados, servicios corriendo y una lista de paquetes desactualizados con un botón Upgrade All",
    "screenshots.alt.outdated":
      "La vista de Paquetes Desactualizados del Dashboard de BrewMenu, listando paquetes con botones de Update individuales y un botón Upgrade All",
    "screenshots.alt.installed":
      "La vista Installed del Dashboard de BrewMenu, listando todas las fórmulas y casks instalados con sus versiones",
    "screenshots.alt.cask":
      "La vista Cask del Dashboard de BrewMenu, listando apps cask instaladas como Brave, Firefox y Visual Studio Code con sus versiones",
    "screenshots.alt.ecosystems":
      "La vista Ecosystems Overview del Dashboard de BrewMenu, agrupando paquetes instalados por tap: dotfn/tap, Cask, Core y taps de terceros",
    "screenshots.alt.recommendedTaps":
      "La vista Recommended Taps del Dashboard de BrewMenu, mostrando taps de terceros curados como HashiCorp, yabai & skhd y 1Password CLI con botones Add Tap",
    "screenshots.alt.thirdParty":
      "La vista Third-Party del Dashboard de BrewMenu, listando paquetes de taps personalizados como dotfn/tap y productdevbook/tap",
    "screenshots.alt.settings":
      "La vista de configuración General del Dashboard de BrewMenu, con toggles para login, contador de updates, comportamiento del ícono de la barra de menú y frecuencia de chequeo",
    "screenshots.lightbox.close": "Cerrar",
    "screenshots.lightbox.prev": "Captura anterior",
    "screenshots.lightbox.next": "Captura siguiente",

    "description.heading": "Qué hace",
    "description.intro":
      "BrewMenu agrega una interfaz visual sobre el Homebrew que ya tenés instalado — no lo reemplaza, y el CLI de brew sigue funcionando exactamente igual.",
    "description.cap1": "Vive en la barra de menú, a un clic en todo momento",
    "description.cap2": "Marca los paquetes desactualizados con un badge y notificaciones nativas",
    "description.cap3": "Actualiza paquetes de a uno o todos juntos",
    "description.cap4": "Busca e instala fórmulas y casks",
    "description.cap5": "Muestra los warnings de brew doctor directamente",
    "description.cap6": "Inicia, detiene y monitorea servicios en segundo plano",
    "description.cap7": "Incluye un Dashboard completo para explorar todo lo instalado",
    "description.closing": "SwiftUI nativo. Sin Electron, sin un daemon en segundo plano drenando tu batería en silencio.",

    "ratings.heading": "Valoraciones y reseñas",
    "ratings.doesNotCollect": "BrewMenu no recolecta valoraciones.",
    "ratings.withStars": "Lo más parecido es GitHub — {stars} estrellas hasta ahora.",
    "ratings.withoutStars": "Lo más parecido es una estrella en GitHub.",
    "ratings.cta": "Dejá la tuya →",

    "privacy.heading": "Privacidad de la app",
    "privacy.intro": "dotfn no recolecta ningún dato de esta app.",
    "privacy.sourceLink": "Mirá el código fuente en GitHub",
    "privacy.dataNotCollected": "No se recolectan datos",
    "privacy.dataNotCollectedBody":
      "BrewMenu solo lee y gestiona tu Cellar de Homebrew local. No accede al resto de tu Mac ni manda nada a un servidor.",

    "accessibility.heading": "Accesibilidad",
    "accessibility.body":
      "Construida con controles nativos de SwiftUI, así que VoiceOver, Dynamic Type y Reduce Motion siguen la configuración de tu sistema por defecto.",

    "infoGrid.heading": "Información",
    "infoGrid.seller": "Vendedor",
    "infoGrid.size": "Tamaño",
    "infoGrid.category": "Categoría",
    "infoGrid.compatibility": "Compatibilidad",
    "infoGrid.compatibility.value": "Requiere macOS 15.0 o posterior",
    "infoGrid.languages": "Idiomas",
    "infoGrid.languages.value": "Inglés, Español",
    "infoGrid.price": "Precio",
    "infoGrid.version": "Versión",
    "infoGrid.copyright": "Copyright",
    "infoGrid.copyright.value": "© 2026 dotfn",
    "infoGrid.developerWebsite": "Sitio del desarrollador",
    "infoGrid.sourceCode": "Código fuente",

    "supports.heading": "Compatible con",
    "supports.openSource": "Código abierto",
    "supports.openSourceBody":
      "Licencia MIT y público en GitHub — leé el código, abrí un issue, o mandá un PR.",

    "install.heading": "Dos minutos para instalar.",
    "install.subheading": "Un solo comando para desinstalar, sin dejar nada atrás.",
    "install.window1Title": "Instalar BrewMenu",
    "install.window2Title": "Instalar Homebrew + BrewMenu",
    "install.uninstallPrefix": "Desinstalá cuando quieras con",
    "install.noBrew": "¿Mac nueva, sin Homebrew todavía? Este one-liner instala los dos.",
    "install.copy": "Copiar",
    "install.copied": "¡Copiado!",

    "faq.heading": "Preguntas",
    "faq.q1": "¿BrewMenu es gratis?",
    "faq.a1": "Sí. BrewMenu es gratis y de código abierto bajo licencia MIT, sin cuenta ni registro.",
    "faq.q2": "¿Reemplaza al CLI de brew?",
    "faq.a2":
      "No. BrewMenu lee y gestiona tu Cellar de Homebrew existente, es una capa visible sobre brew, no un reemplazo. El CLI sigue funcionando exactamente igual.",
    "faq.q3": "¿Qué versiones de macOS soporta?",
    "faq.a3": "macOS 15 (Sequoia) en adelante. Los sistemas más viejos todavía no están soportados.",
    "faq.q4": "¿Mis datos se mandan a algún lado?",
    "faq.a4":
      "No. BrewMenu solo lee y gestiona tu Cellar de Homebrew local. No tiene acceso al resto de tu Mac ni manda datos a ningún servidor.",

    "moreBy.heading": "Más de dotfn",
    "moreBy.site": "dotfn.dev",
    "moreBy.siteBody": "Sitio del estudio y otros proyectos",
    "moreBy.github": "GitHub",
    "moreBy.githubBody": "Código fuente y otros repos",
    "moreBy.x": "X / Twitter",
    "moreBy.xBody": "Novedades del build in public",
    "moreBy.view": "Ver",

    "footer.copyright": "Copyright © 2026 dotfn. Todos los derechos reservados.",
    "footer.github": "GitHub",
    "footer.releases": "Releases",
    "footer.license": "Licencia MIT",
  },
} as const;
