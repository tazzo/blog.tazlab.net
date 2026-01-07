+++
title = "Architettura e Configurazione Avanzata del Tema Blowfish per Hugo: Una Disamina Tecnica Integrale"
date = 2026-01-07
draft = false
description = "Un'analisi tecnica approfondita del tema Blowfish per Hugo, coprendo configurazione, personalizzazione e prestazioni."
tags = ["hugo", "blowfish", "theme", "web-development", "static-site-generator", "css"]
author = "Tazzo"
+++

Il panorama dei generatori di siti statici (SSG) ha subito un'evoluzione paradigmatica negli ultimi anni, con Hugo che si è affermato come una delle soluzioni più performanti grazie alla sua velocità di compilazione quasi istantanea e alla sua robusta architettura in Go. In questo contesto, il tema Blowfish emerge non come un semplice template grafico, ma come un framework modulare e sofisticato, costruito sopra Tailwind CSS 3.0, progettato per soddisfare le esigenze di sviluppatori, ricercatori e creatori di contenuti che richiedono un equilibrio impeccabile tra estetica minimalista e potenza funzionale.1 Blowfish si distingue per la sua capacità di gestire flussi di lavoro complessi, integrazioni serverless e una personalizzazione granulare che va ben oltre la superficie visiva, posizionandosi come uno dei temi più avanzati nell'ecosistema Hugo.1

## **Evoluzione e Filosofia Progettuale di Blowfish**

La genesi di Blowfish risiede nella necessità di superare i limiti dei temi monolitici, offrendo una struttura che privilegia l'ottimizzazione automatizzata degli asset e l'accessibilità out-of-the-box. L'adozione di Tailwind CSS non è solo una scelta estetica, ma una decisione architettonica che permette di generare bundle CSS estremamente ridotti, contenenti solo le classi effettivamente utilizzate, garantendo prestazioni di alto livello documentate da punteggi eccellenti nei test Lighthouse.1 Il tema è intrinsecamente orientato al contenuto, strutturato per sfruttare appieno i "Page Bundles" di Hugo, un sistema che organizza le risorse multimediali direttamente accanto ai file di testo, migliorando la portabilità e la manutenibilità del progetto nel lungo periodo.5

L'architettura di Blowfish è progettata per essere "future-proof", supportando nativamente integrazioni dinamiche in un ambiente statico, come il conteggio delle visualizzazioni e i sistemi di interazione tramite Firebase, la ricerca avanzata lato client con Fuse.js e la visualizzazione di dati complessi tramite Chart.js e Mermaid.1 Questa versatilità lo rende adatto a una vasta gamma di applicazioni, dal blog personale alla documentazione tecnica di livello enterprise.

## **Procedure di Installazione e Inizializzazione del Progetto**

L'implementazione di Blowfish richiede un ambiente di sviluppo configurato correttamente con Hugo (versione 0.87.0 o superiore, preferibilmente la versione "extended") e Git.3 Esistono tre percorsi principali per l'installazione, ognuno con implicazioni specifiche sulla gestione del workflow.

### **Metodologia CLI: Blowfish Tools**

L'approccio più moderno e consigliato per i nuovi utenti è l'utilizzo di blowfish-tools, uno strumento a riga di comando che automatizza la creazione del sito e la configurazione iniziale.3

| Comando | Funzione | Contesto d'Uso |
| :---- | :---- | :---- |
| npm i \-g blowfish-tools | Installazione globale | Preparazione dell'ambiente di sviluppo Node.js. |
| blowfish-tools new | Creazione sito completo | Ideale per nuovi progetti partendo da zero. |
| blowfish-tools | Menu interattivo | Configurazione di funzionalità specifiche in progetti esistenti. |

Questo strumento riduce significativamente la barriera all'ingresso, gestendo la creazione della complessa struttura di cartelle richiesta per una configurazione modulare.5

### **Metodologia Professionale: Moduli Hugo e Sottomoduli Git**

Per i professionisti che operano in ambienti di Continuous Integration (CI), l'uso dei Moduli Hugo rappresenta la soluzione più elegante. Questo metodo tratta il tema come una dipendenza gestita da Go, permettendo aggiornamenti rapidi tramite il comando hugo mod get \-u.1 In alternativa, l'installazione come sottomodulo Git (git submodule add https://github.com/nunocoracao/blowfish.git themes/blowfish) è preferibile per chi desidera mantenere il codice del tema all'interno del proprio repository senza però mescolarlo con il contenuto, facilitando il tracciamento delle versioni specifiche.1

## **Il Sistema di Configurazione Modulare**

Una delle caratteristiche distintive di Blowfish è l'abbandono del singolo file config.toml in favore di una directory config/\_default/ contenente file TOML specializzati. Questa separazione logica è fondamentale per gestire la complessità delle opzioni offerte dal tema.2

### **Hugo.toml: La Struttura Portante del Sito**

Il file hugo.toml (o config.toml se non si utilizza la struttura modulare) definisce i parametri globali del motore Hugo e le impostazioni di base del sito.8

| Parametro | Descrizione | Rilevanza Tecnica |
| :---- | :---- | :---- |
| baseURL | URL radice del sito | Essenziale per la generazione corretta di link assoluti e SEO.4 |
| theme | "blowfish" | Indica a Hugo quale tema caricare (omissibile con i Moduli).8 |
| defaultContentLanguage | Lingua predefinita | Determina le traduzioni i18n da utilizzare inizialmente.8 |
| outputs.home | \`\` | Cruciale: il formato JSON è necessario per la ricerca interna.8 |
| summaryLength | Lunghezza riassunto | Un valore di 0 indica a Hugo di usare la prima frase come sommario.8 |

L'abilitazione del formato JSON nella homepage è un passaggio tecnico critico spesso trascurato; senza di esso, il modulo di ricerca Fuse.js non avrà un indice da interrogare, rendendo la barra di ricerca non funzionale.8

### **Params.toml: Il Pannello di Controllo delle Funzionalità**

Il file params.toml ospita le configurazioni specifiche del tema, permettendo di attivare o disattivare moduli complessi senza modificare il codice sorgente.4

La gestione dell'aspetto visivo è controllata dai parametri defaultAppearance e autoSwitchAppearance. Il primo definisce se il sito debba caricarsi in modalità "light" o "dark", mentre il secondo, se impostato su true, permette al sito di rispettare le preferenze del sistema operativo dell'utente, garantendo un'esperienza visiva coerente con l'ecosistema del visitatore.8 Inoltre, il parametro colorScheme permette di selezionare una delle palette predefinite, ognuna delle quali trasforma radicalmente l'identità cromatica del sito senza richiedere modifiche CSS manuali.5

### **L'Architettura Multilingue e la Configurazione dell'Autore**

Blowfish eccelle nel supporto multilingue, richiedendo un file di configurazione dedicato per ogni lingua (es. languages.it.toml).5 In questo file vengono definiti non solo il titolo del sito per quella specifica lingua, ma anche i metadati dell'autore che appariranno nei box biografici sotto gli articoli.2

| Campo Autore | Funzione | Impatto UI |
| :---- | :---- | :---- |
| name | Nome dell'autore | Visualizzato nell'header e nel footer degli articoli.2 |
| image | Avatar dell'autore | Immagine profilo circolare nei widget biografici.2 |
| headline | Breve slogan | Testo di impatto visualizzato nella homepage layout "profile".2 |
| bio | Biografia completa | Testo descrittivo visualizzato nel footer dei post se showAuthor è attivo.7 |
| links | Social media | Array di icone cliccabili che collegano ai profili esterni.2 |

Questo approccio permette una personalizzazione estrema: un sito può avere autori diversi per versioni linguistiche diverse, o semplicemente tradurre la biografia dell'autore principale per adattarsi al pubblico locale.5

### **Navigazione e Menu: Gerarchie e Iconografia**

La configurazione dei menu avviene tramite file dedicati come menus.en.toml o menus.it.toml. Blowfish supporta tre aree di navigazione principali: il menu main (header), il menu footer e la subnavigation.5

Il tema introduce un sistema di icone semplificato tramite il parametro pre, che permette di inserire icone SVG (come quelle di FontAwesome o icone social) direttamente accanto al testo del menu.5 Un aspetto avanzato è il supporto ai menu nidificati: definendo un elemento con un identifier unico e impostando altri elementi con un parametro parent corrispondente a quell'identificativo, Blowfish genererà automaticamente menu a discesa eleganti e funzionali.5

## **Gestione dei Contenuti: Page Bundles e Tassonomie**

La forza di Hugo, e di Blowfish in particolare, risiede nella gestione strutturata dei contenuti. Il tema è progettato per operare in armonia con il concetto di "Page Bundles", distinguendo tra Branch Pages e Leaf Pages.5

### **Branch Pages e l'Organizzazione delle Sezioni**

Le Branch Pages sono nodi della gerarchia che contengono altri file, come le homepage di sezione o le liste di categorie. Sono identificate dal file \_index.md. Blowfish onora i parametri nel front matter di questi file, permettendo di sovrascrivere le impostazioni globali per una specifica sezione del sito.6 Ad esempio, è possibile decidere che la sezione "Portfolio" utilizzi una visualizzazione a card, mentre la sezione "Blog" utilizzi una lista classica.6

### **Leaf Pages e la Gestione degli Asset**

Le Leaf Pages rappresentano il contenuto atomico, come un singolo post o una pagina "About". Se un articolo include immagini o altri media, deve essere creato come un "bundle": una directory con il nome dell'articolo contenente un file index.md (senza underscore) e tutti gli asset correlati.6 Questo sistema non solo mantiene l'ordine nel filesystem, ma permette a Blowfish di processare le immagini tramite Hugo Pipes per ottimizzarne il peso e le dimensioni automaticamente.1

### **Integrazione di Contenuti Esterni**

Blowfish offre una funzionalità sofisticata per includere link a piattaforme esterne (come Medium, LinkedIn o repository GitHub) direttamente nel flusso degli articoli del sito.1 Utilizzando il parametro externalUrl nel front matter e istruendo Hugo a non generare una pagina locale (build: render: "false"), il post apparirà nell'elenco degli articoli ma reindirizzerà l'utente direttamente alla risorsa esterna, mantenendo però la coerenza visiva e la categorizzazione interna del sito.6

## **Visual Support e Media Optimization**

L'impatto visivo di Blowfish è fortemente legato alla sua gestione delle immagini, che bilancia l'estetica con le prestazioni attraverso l'uso di tecnologie moderne come il lazy-loading e il ridimensionamento dinamico.1

### **Immagini in Evidenza e Hero Sections**

Per impostare un'immagine di anteprima che appaia nelle card e nell'intestazione di un articolo, Blowfish segue una convenzione di denominazione rigorosa: il file deve iniziare con feature\* (es. feature.png, featured-image.jpg) e trovarsi nella cartella dell'articolo.5 Queste immagini non solo fungono da thumbnail, ma vengono utilizzate per generare i metadati Open Graph necessari per una corretta visualizzazione sui social media tramite il protocollo oEmbed.7

Il layout dell'intestazione (Hero Style) può essere configurato globalmente o per singolo post:

| Stile Hero | Effetto Visivo | Uso Consigliato |
| :---- | :---- | :---- |
| basic | Layout semplice con titolo e immagine affiancati. | Post informativi standard.7 |
| big | Immagine grande sopra il titolo con supporto a didascalie. | Articoli di copertina o long-form.7 |
| background | L'immagine di feature diventa lo sfondo dell'intestazione. | Pagine d'impatto o landing pages.7 |
| thumbAndBackground | Combina l'immagine di sfondo con una thumbnail in primo piano. | Brand identity forte o portfolio.7 |

### **Sfondi Personalizzati e Immagini di Sistema**

Blowfish permette di definire sfondi globali tramite il parametro defaultBackgroundImage in params.toml. Per garantire tempi di caricamento rapidi, il tema scala automaticamente queste immagini a una larghezza predefinita (solitamente 1200px), riducendo il consumo di dati per gli utenti su dispositivi mobili.7 Inoltre, è possibile disabilitare globalmente lo zoom delle immagini o l'ottimizzazione per scenari specifici dove la fedeltà visiva assoluta è prioritaria rispetto alle prestazioni.8

## **Rich Content e Shortcodes Avanzati**

Gli shortcode di Blowfish estendono le capacità del Markdown standard, permettendo l'inserimento di componenti UI complessi senza scrivere codice HTML.16

### **Alerts e Callouts**

Lo shortcode alert è uno strumento fondamentale per la comunicazione tecnica, permettendo di evidenziare avvertimenti, note o suggerimenti. Supporta parametri per l'icona, il colore della card, il colore dell'icona e il colore del testo, garantendo che l'avviso sia perfettamente in linea con il contesto semantico del contenuto.16

Esempio di utilizzo con parametri nominati:  
{{\< alert icon="fire" cardColor="\#e63946" iconColor="\#1d3557" textColor="\#f1faee" \>}}  
Messaggio di errore critico\!  
{{\< /alert \>}}.16

### **Caroselli e Gallerie Interattive**

Per la gestione di molteplici immagini, lo shortcode carousel offre un'interfaccia scorrevole ed elegante. Una funzione particolarmente potente è la possibilità di passare una stringa regex al parametro images (es. images="gallery/\*"), istruendo il tema a caricare automaticamente tutte le immagini presenti in una specifica sottodirectory del Page Bundle.16 Questo elimina la necessità di aggiornare manualmente il codice Markdown ogni volta che viene aggiunta una foto alla galleria.

### **Figure ed Embedding Video**

Lo shortcode figure di Blowfish sostituisce quello nativo di Hugo offrendo prestazioni superiori tramite l'ottimizzazione delle immagini basata sulla risoluzione del dispositivo (Responsive Images). Supporta didascalie in Markdown, link ipertestuali sull'immagine e il controllo granulare sulla funzione di zoom.16

Per quanto riguarda il video, Blowfish fornisce wrapper responsivi per YouTube, Vimeo e file locali. L'uso dello shortcode youtubeLite è raccomandato per i siti che puntano alla massima velocità: invece di caricare l'intero iframe di Google all'avvio della pagina, carica solo una miniatura leggera, attivando il player pesante solo quando l'utente clicca effettivamente sul tasto play.16

## **Comunicazione Scientifica: Matematica e Diagrammi**

Blowfish è diventato uno standard de facto per i blog accademici e tecnici grazie alla sua integrazione nativa con strumenti di typesetting e visualizzazione dati di alto livello.1

### **Notazione Matematica con KaTeX**

Il rendering delle formule matematiche è affidato a KaTeX, noto per essere il motore di typesetting matematico più veloce per il web. Per preservare le prestazioni, Blowfish non carica gli asset di KaTeX globalmente; vengono inclusi nel bundle della pagina solo se viene rilevato lo shortcode {{\< katex \>}} all'interno dell'articolo.16

La sintassi supportata segue gli standard LaTeX:

* **Notazione Inline**: Formule inserite nel flusso del testo tramite i delimitatori \\( e \\). Esempio: $\\nabla \\cdot \\mathbf{E} \= \\frac{\\rho}{\\varepsilon\_0}$.18  
* Notazione a Blocco: Formule centrate e isolate tramite i delimitatori $$. Esempio:

  $$e^{i\\pi} \+ 1 \= 0$$  
  .18

Questa implementazione permette di scrivere equazioni complesse che rimangono leggibili e ricercabili, con un impatto nullo sulla velocità di caricamento delle pagine non scientifiche del sito.

### **Diagrammi e Grafici Dinamici**

Attraverso gli shortcode mermaid e chart, Blowfish permette di generare visualizzazioni complesse partendo da dati testuali.1

* **Mermaid.js**: Consente la creazione di diagrammi di flusso, diagrammi di sequenza, grafi di Gantt e diagrammi di classe utilizzando una sintassi testuale semplice. È ideale per documentare architetture software o processi logici senza dover gestire file immagine esterni.1  
* **Chart.js**: Permette di incorporare grafici a barre, a torta, a linee e radar fornendo dati strutturati direttamente nello shortcode. Poiché i grafici sono renderizzati su un elemento HTML5 Canvas, rimangono nitidi a qualsiasi livello di zoom e sono interattivi (mostrano i valori al passaggio del mouse).1

## **Integrazioni Dinamiche e Dynamic Data Support**

Nonostante la sua natura statica, Blowfish può evolversi in una piattaforma dinamica grazie all'integrazione intelligente con servizi serverless, in particolare Firebase.1

### **Firebase: Views, Likes e Analytics Dinamici**

L'integrazione con Firebase permette di aggiungere funzionalità tipiche dei sistemi CMS tradizionali, come il conteggio delle visualizzazioni in tempo reale e il sistema di "like" per gli articoli.1 Il processo di configurazione prevede:

1. Creazione di un progetto Firebase e abilitazione del database Firestore in modalità produzione.9  
2. Configurazione delle regole di sicurezza per permettere letture e scritture anonime (previa abilitazione dell'Anonymous Authentication).9  
3. Inserimento delle chiavi API nel file params.toml sotto la sezione Firebase.8

Una volta configurato, Blowfish gestisce automaticamente l'incremento delle visualizzazioni ogni volta che una pagina viene caricata, memorizzando i dati nel database serverless e visualizzandoli negli elenchi degli articoli.8

### **Ricerca Avanzata con Fuse.js**

La ricerca interna di Blowfish non richiede database esterni. Durante la fase di build, Hugo genera un file index.json contenente il titolo, il sommario e il contenuto di tutti gli articoli.1 Fuse.js, una libreria di ricerca fuzzy leggera, scarica questo indice e permette ricerche istantanee direttamente nel browser dell'utente. Per garantire il funzionamento di questa feature, è imperativo che la configurazione outputs.home includa il formato JSON.8

## **SEO, Accessibilità e Ottimizzazione per i Motori di Ricerca**

Blowfish è costruito seguendo le migliori pratiche SEO per garantire che i contenuti siano facilmente indicizzabili e presentati in modo ottimale sui social media.1

### **Metadati e Structured Data**

Il tema genera automaticamente tag meta Open Graph e Twitter Cards, utilizzando l'immagine di feature dell'articolo e la descrizione fornita nel front matter. Se non viene fornita una descrizione, Blowfish utilizza il sommario generato automaticamente da Hugo.7 Inoltre, il supporto per i breadcrumbs strutturati (abilitabile tramite enableStructuredBreadcrumbs) aiuta i motori di ricerca a comprendere la gerarchia del sito e a visualizzare percorsi di navigazione puliti nei risultati di ricerca.8

### **Performance e Lighthouse Scores**

L'ottimizzazione delle prestazioni non è solo una questione di velocità, ma un fattore di ranking critico (Core Web Vitals). Blowfish ottiene punteggi vicini al 100 in tutte le categorie Lighthouse grazie a:

* Generazione di CSS critico minimo tramite Tailwind.1  
* Lazy-loading nativo per tutte le immagini.8  
* Minimizzazione degli asset JS.1  
* Supporto nativo per i formati immagine moderni come WebP (tramite Hugo Pipes).1

## **Strategie di Deployment e Pipeline di Produzione**

La natura statica dei siti generati con Blowfish permette una distribuzione globale ed economica tramite CDN (Content Delivery Networks).12

### **Hosting e Continuous Deployment**

Le piattaforme di hosting moderne offrono integrazioni dirette con GitHub o GitLab, automatizzando il processo di build e deployment.

| Piattaforma | Metodo di Build | Note Tecniche |
| :---- | :---- | :---- |
| **GitHub Pages** | GitHub Actions | Richiede la creazione di un workflow YAML che esegua hugo \--gc \--minify.4 |
| **Netlify** | Build Bot interno | Configurazione tramite netlify.toml; supporta le preview dei branch e i form.3 |
| **Firebase Hosting** | Firebase CLI | Ideale se si utilizza già Firebase per le visualizzazioni e i like.9 |

Durante la configurazione del deployment, è fondamentale impostare correttamente la variabile baseURL per l'ambiente di produzione, specialmente se il sito risiede in una sottocartella, per evitare che gli asset (CSS, immagini) vengano caricati da percorsi errati.4

## **Conclusioni: Verso un Web Statico senza Compromessi**

La configurazione del tema Blowfish per Hugo rappresenta un esercizio di bilanciamento tra la semplicità della gestione dei contenuti in Markdown e la complessità delle esigenze tecnologiche moderne. Attraverso una struttura modulare, un'attenzione maniacale alle prestazioni e una serie di integrazioni di alto livello per dati scientifici e dinamici, Blowfish si conferma come una soluzione d'eccellenza per la realizzazione di siti web professionali.1

L'adozione di questo tema permette agli sviluppatori di concentrarsi sulla qualità del contenuto e sulla struttura dell'informazione, delegando al framework la gestione degli aspetti tecnici legati all'accessibilità, alla SEO e all'ottimizzazione degli asset. In un ecosistema web sempre più esigente, Blowfish offre gli strumenti necessari per costruire una presenza online solida, performante e visivamente appagante, definendo lo stato dell'arte per i temi Hugo di nuova generazione.3

#### **Bibliografia**

1. Blowfish | Hugo Themes, accesso eseguito il giorno gennaio 3, 2026, [https://www.gohugothemes.com/theme/nunocoracao-blowfish/](https://www.gohugothemes.com/theme/nunocoracao-blowfish/)  
2. Gitlab Pages, Hugo and Blowfish to set up your website in minutes \- Mariano González, accesso eseguito il giorno gennaio 3, 2026, [https://blog.mariano.cloud/your-website-in-minutes-gitlab-hugo-blowfish](https://blog.mariano.cloud/your-website-in-minutes-gitlab-hugo-blowfish)  
3. nunocoracao/blowfish: Personal Website & Blog Theme for Hugo \- GitHub, accesso eseguito il giorno gennaio 3, 2026, [https://github.com/nunocoracao/blowfish](https://github.com/nunocoracao/blowfish)  
4. Blowfish \- True Position Tools, accesso eseguito il giorno gennaio 3, 2026, [https://truepositiontools.com/crypto/blowfish-guide](https://truepositiontools.com/crypto/blowfish-guide)  
5. Getting Started \- Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/getting-started/](https://blowfish.page/docs/getting-started/)  
6. Content Examples · Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/content-examples/](https://blowfish.page/docs/content-examples/)  
7. Thumbnails · Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/thumbnails/](https://blowfish.page/docs/thumbnails/)  
8. Configuration \- Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/configuration/](https://blowfish.page/docs/configuration/)  
9. Firebase: Views & Likes \- Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/firebase-views/](https://blowfish.page/docs/firebase-views/)  
10. Installation \- Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/installation/](https://blowfish.page/docs/installation/)  
11. How To Make A Hugo Blowfish Website \- YouTube, accesso eseguito il giorno gennaio 3, 2026, [https://www.youtube.com/watch?v=-05mOdHmQVc](https://www.youtube.com/watch?v=-05mOdHmQVc)  
12. A Beginner-Friendly Tutorial for Building a Blog with Hugo, the Blowfish Theme, and GitHub Pages, accesso eseguito il giorno gennaio 3, 2026, [https://www.gigigatgat.ca/en/posts/how-to-create-a-blog/](https://www.gigigatgat.ca/en/posts/how-to-create-a-blog/)  
13. Step-by-Step Guide to Creating a Hugo Website · \- dasarpAI, accesso eseguito il giorno gennaio 3, 2026, [https://main--dasarpai.netlify.app/dsblog/step-by-step-guide-creating-hugo-website/](https://main--dasarpai.netlify.app/dsblog/step-by-step-guide-creating-hugo-website/)  
14. Partials \- Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/partials/](https://blowfish.page/docs/partials/)  
15. Build your homepage using Blowfish and Hugo · N9O \- Nuno Coração, accesso eseguito il giorno gennaio 3, 2026, [https://n9o.xyz/posts/202310-blowfish-tutorial/](https://n9o.xyz/posts/202310-blowfish-tutorial/)  
16. Shortcodes · Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/docs/shortcodes/](https://blowfish.page/docs/shortcodes/)  
17. Shortcodes \- Hugo, accesso eseguito il giorno gennaio 3, 2026, [https://gohugo.io/content-management/shortcodes/](https://gohugo.io/content-management/shortcodes/)  
18. Mathematical notation · Blowfish, accesso eseguito il giorno gennaio 3, 2026, [https://blowfish.page/samples/mathematical-notation/](https://blowfish.page/samples/mathematical-notation/)  
19. Hosting & Deployment \- Deepfaces, accesso eseguito il giorno gennaio 3, 2026, [https://deepfaces.pt/docs/hosting-deployment/](https://deepfaces.pt/docs/hosting-deployment/)  
20. Getting Started With Hugo | FREE COURSE \- YouTube, accesso eseguito il giorno gennaio 3, 2026, [https://www.youtube.com/watch?v=hjD9jTi\_DQ4](https://www.youtube.com/watch?v=hjD9jTi_DQ4)