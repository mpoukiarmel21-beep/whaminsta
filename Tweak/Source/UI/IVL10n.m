//
//  IVL10n.m
//  whaminsta
//
//  Implémentation du système de localisation. Définit la langue cible une fois
//  (à la 1re résolution), puis rend les chaînes depuis une table. Repli sûr :
//  langue cible absente -> français (source) -> clé brute jamais.
//

#import "IVL10n.h"
#import "../Spoof/IVLocaleSpoof.h"
#import <UIKit/UIKit.h>

// Table de traduction : clé -> { langue : chaîne }.
// "fr" est la source (obligatoire). Les autres langues sont optionnelles mais
// couvertes pour toutes les clés listées afin d'éviter les trous d'UI.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *IVL10nTable(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString * (^FR)(NSString *) = ^NSString *(NSString *s) { return s; };
        t = @{
            // ---- FloatingButton ----
            @"fb.open"          : @{ @"fr" : FR(@"Ouvrir"), @"en" : @"Open", @"es" : @"Abrir", @"de" : @"Öffnen", @"it" : @"Apri", @"pt" : @"Abrir" },

            // ---- Panneau principal ----
            @"panel.title"      : @{ @"fr" : FR(@"Conteneurs"), @"en" : @"Containers", @"es" : @"Contenedores", @"de" : @"Container", @"it" : @"Contenitori", @"pt" : @"Contêineres" },
            @"panel.create"     : @{ @"fr" : FR(@"Créer un conteneur"), @"en" : @"Create a container", @"es" : @"Crear un contenedor", @"de" : @"Container erstellen", @"it" : @"Crea un contenitore", @"pt" : @"Criar um contêiner" },
            @"panel.default"    : @{ @"fr" : FR(@"Compte réel (téléphone)"), @"en" : @"Real account (phone)", @"es" : @"Cuenta real (teléfono)", @"de" : @"Echtes Konto (Telefon)", @"it" : @"Account reale (telefono)", @"pt" : @"Conta real (telefone)" },
            @"panel.activate"   : @{ @"fr" : FR(@"Activer ce conteneur"), @"en" : @"Activate this container", @"es" : @"Activar este contenedor", @"de" : @"Diesen Container aktivieren", @"it" : @"Attiva questo contenitore", @"pt" : @"Ativar este contêiner" },
            @"panel.rename"     : @{ @"fr" : FR(@"Renommer"), @"en" : @"Rename", @"es" : @"Renombrar", @"de" : @"Umbenennen", @"it" : @"Rinomina", @"pt" : @"Renomear" },
            @"panel.delete"     : @{ @"fr" : FR(@"Supprimer"), @"en" : @"Delete", @"es" : @"Eliminar", @"de" : @"Löschen", @"it" : @"Elimina", @"pt" : @"Excluir" },
            @"panel.langs"      : @{ @"fr" : FR(@"Langue & région"), @"en" : @"Language & region", @"es" : @"Idioma y región", @"de" : @"Sprache und Region", @"it" : @"Lingua e regione", @"pt" : @"Idioma e região" },
            @"panel.locale"     : @{ @"fr" : FR(@"Langue de l'application"), @"en" : @"App language", @"es" : @"Idioma de la aplicación", @"de" : @"App-Sprache", @"it" : @"Lingua dell'app", @"pt" : @"Idioma do aplicativo" },
            @"panel.region"     : @{ @"fr" : FR(@"Pays / région"), @"en" : @"Country / region", @"es" : @"País / región", @"de" : @"Land / Region", @"it" : @"Paese / regione", @"pt" : @"País / região" },
            @"panel.auto"       : @{ @"fr" : FR(@"Automatique (système)"), @"en" : @"Automatic (system)", @"es" : @"Automático (sistema)", @"de" : @"Automatisch (System)", @"it" : @"Automatico (sistema)", @"pt" : @"Automático (sistema)" },
            @"panel.camera"     : @{ @"fr" : FR(@"Caméra"), @"en" : @"Camera", @"es" : @"Cámara", @"de" : @"Kamera", @"it" : @"Fotocamera", @"pt" : @"Câmera" },
            @"panel.swipe"      : @{ @"fr" : FR(@"Auto-swipe"), @"en" : @"Auto-swipe", @"es" : @"Auto-swipe", @"de" : @"Auto-Swipe", @"it" : @"Auto-swipe", @"pt" : @"Auto-swipe" },
            @"panel.reset"      : @{ @"fr" : FR(@"Réinitialiser tout"), @"en" : @"Reset everything", @"es" : @"Restablecer todo", @"de" : @"Alles zurücksetzen", @"it" : @"Azzera tutto", @"pt" : @"Redefinir tudo" },
            @"panel.logs"       : @{ @"fr" : FR(@"Journal / Logs"), @"en" : @"Journal / Logs", @"es" : @"Registro / Logs", @"de" : @"Journal / Logs", @"it" : @"Registro / Log", @"pt" : @"Registro / Logs" },
            @"panel.close"      : @{ @"fr" : FR(@"Fermer"), @"en" : @"Close", @"es" : @"Cerrar", @"de" : @"Schließen", @"it" : @"Chiudi", @"pt" : @"Fechar" },
            @"panel.cancel"     : @{ @"fr" : FR(@"Annuler"), @"en" : @"Cancel", @"es" : @"Cancelar", @"de" : @"Abbrechen", @"it" : @"Annulla", @"pt" : @"Cancelar" },
            @"common.ok"        : @{ @"fr" : FR(@"OK"), @"en" : @"OK", @"es" : @"OK", @"de" : @"OK", @"it" : @"OK", @"pt" : @"OK" },
            @"common.none"      : @{ @"fr" : FR(@"(aucune)"), @"en" : @"(none)", @"es" : @"(ninguna)", @"de" : @"(keine)", @"it" : @"(nessuno)", @"pt" : @"(nenhuma)" },
            @"common.fail"      : @{ @"fr" : FR(@"Échec"), @"en" : @"Failed", @"es" : @"Error", @"de" : @"Fehler", @"it" : @"Errore", @"pt" : @"Falha" },
            @"common.savefail.t": @{ @"fr" : FR(@"Échec de l'enregistrement"), @"en" : @"Save failed", @"es" : @"Error al guardar", @"de" : @"Speichern fehlgeschlagen", @"it" : @"Salvataggio non riuscito", @"pt" : @"Falha ao salvar" },
            @"common.savefail.m": @{ @"fr" : FR(@"La configuration n'a pas pu être enregistrée (écriture disque échouée). Réessaie."), @"en" : @"The configuration could not be saved (disk write failed). Try again.", @"es" : @"No se pudo guardar la configuración (error de escritura). Inténtalo de nuevo.", @"de" : @"Die Konfiguration konnte nicht gespeichert werden (Schreibfehler). Versuch es erneut.", @"it" : @"Impossibile salvare la configurazione (errore di scrittura). Riprova.", @"pt" : @"Não foi possível salvar a configuração (falha de gravação). Tente novamente." },
            @"panel.active"     : @{ @"fr" : FR(@"Conteneur actif"), @"en" : @"Active container", @"es" : @"Contenedor activo", @"de" : @"Aktiver Container", @"it" : @"Contenitore attivo", @"pt" : @"Contêiner ativo" },
            @"panel.activated"  : @{ @"fr" : FR(@"Conteneur activé"), @"en" : @"Container activated", @"es" : @"Contenedor activado", @"de" : @"Container aktiviert", @"it" : @"Contenitore attivato", @"pt" : @"Contêiner ativado" },
            @"panel.activated.m": @{ @"fr" : FR(@"« %@ » est prêt.\nL'app va se fermer — rouvre-la pour l'utiliser."), @"en" : @"\u00ab %@ \u00bb is ready.\nThe app will close — reopen it to use it.", @"es" : @"\u00ab %@ \u00bb está listo.\nLa aplicación se cerrará; vuelve a abrirla para usarla.", @"de" : @"\u00ab %@ \u00bb ist bereit.\nDie App wird geschlossen — öffne sie erneut, um sie zu nutzen.", @"it" : @"\u00ab %@ \u00bb è pronto.\nL'app si chiuderà; riapri per usarla.", @"pt" : @"\u00ab %@ \u00bb está pronto.\nO app fechará; reabra para usá-lo." },
            @"panel.device"     : @{ @"fr" : FR(@"Appareil (infos)"), @"en" : @"Device (info)", @"es" : @"Dispositivo (info)", @"de" : @"Gerät (Info)", @"it" : @"Dispositivo (info)", @"pt" : @"Dispositivo (info)" },
            @"panel.settingsFor": @{ @"fr" : FR(@"Réglages — %@"), @"en" : @"Settings — %@", @"es" : @"Ajustes — %@", @"de" : @"Einstellungen — %@", @"it" : @"Impostazioni — %@", @"pt" : @"Configurações — %@" },
            @"panel.settings.note": @{ @"fr" : FR(@"Prend effet au prochain démarrage de l'app."), @"en" : @"Takes effect on the next app start.", @"es" : @"Tiene efecto en el próximo inicio de la app.", @"de" : @"Wird beim nächsten App-Start wirksam.", @"it" : @"Ha effetto al prossimo avvio dell'app.", @"pt" : @"Entra em vigor na próxima inicialização do app." },
            @"panel.langFmt"    : @{ @"fr" : FR(@"Langue : %@"), @"en" : @"Language: %@", @"es" : @"Idioma: %@", @"de" : @"Sprache: %@", @"it" : @"Lingua: %@", @"pt" : @"Idioma: %@" },
            @"panel.regionFmt"  : @{ @"fr" : FR(@"Région : %@"), @"en" : @"Region: %@", @"es" : @"Región: %@", @"de" : @"Region: %@", @"it" : @"Regione: %@", @"pt" : @"Região: %@" },
            @"panel.switchFoot" : @{ @"fr" : FR(@"Changer de conteneur actif…"), @"en" : @"Switch the active container…", @"es" : @"Cambiar el contenedor activo…", @"de" : @"Aktiven Container wechseln…", @"it" : @"Cambia il contenitore attivo…", @"pt" : @"Mudar o contêiner ativo…" },
            @"panel.isoNote"    : @{ @"fr" : FR(@"Isolation inactive — vous êtes sur le compte réel. Ne vous connectez pas ici ; fermez complètement l'app puis rouvrez-la."), @"en" : @"Isolation inactive — you are on the real account. Do not sign in here; fully close the app then reopen it.", @"es" : @"Aislamiento inactivo — estás en la cuenta real. No inicies sesión aquí; cierra la app por completo y vuelve a abrirla.", @"de" : @"Isolation inaktiv — Sie sind im echten Konto. Melden Sie sich hier nicht an; schließen Sie die App vollständig und öffnen Sie sie erneut.", @"it" : @"Isolamento inattivo — sei sull'account reale. Non accedere qui; chiudi completamente l'app e riapri.", @"pt" : @"Isolamento inativo — você está na conta real. Não entre aqui; feche o app por completo e reabra." },
            @"panel.reseted"    : @{ @"fr" : FR(@"Réinitialisé"), @"en" : @"Reset", @"es" : @"Restablecido", @"de" : @"Zurückgesetzt", @"it" : @"Azzarato", @"pt" : @"Redefinido" },
            @"panel.reseted.m"  : @{ @"fr" : FR(@"Compte déconnecté et données effacées."), @"en" : @"Account signed out and data cleared.", @"es" : @"Cuenta cerrada y datos borrados.", @"de" : @"Konto abgemeldet und Daten gelöscht.", @"it" : @"Account scollegato e dati cancellati.", @"pt" : @"Conta desconectada e dados removidos." },
            @"panel.cam.set"    : @{ @"fr" : FR(@"Vidéo de vérification définie ✓ (partagée par tous les conteneurs)"), @"en" : @"Verification video set ✓ (shared by all containers)", @"es" : @"Video de verificación definido ✓ (compartido por todos los contenedores)", @"de" : @"Verifizierungsvideo festgelegt ✓ (von allen Containern geteilt)", @"it" : @"Video di verifica impostato ✓ (condiviso da tutti i contenitori)", @"pt" : @"Vídeo de verificação definido ✓ (compartilhado por todos os contêineres)" },
            @"panel.cam.change" : @{ @"fr" : FR(@"Changer la vidéo"), @"en" : @"Change video", @"es" : @"Cambiar video", @"de" : @"Video wechseln", @"it" : @"Cambia video", @"pt" : @"Trocar vídeo" },
            @"panel.cam.remove" : @{ @"fr" : FR(@"Retirer la vidéo"), @"en" : @"Remove video", @"es" : @"Quitar video", @"de" : @"Video entfernen", @"it" : @"Rimuovi video", @"pt" : @"Remover vídeo" },
            @"panel.delete.msg" : @{ @"fr" : FR(@"Toutes ses données (comptes, réglages) seront effacées définitivement."), @"en" : @"All its data (accounts, settings) will be permanently erased.", @"es" : @"Todos sus datos (cuentas, ajustes) se borrarán definitivamente.", @"de" : @"Alle Daten (Konten, Einstellungen) werden dauerhaft gelöscht.", @"it" : @"Tutti i dati (account, impostazioni) verranno cancellati definitivamente.", @"pt" : @"Todos os seus dados (contas, configurações) serão apagados definitivamente." },
            @"panel.delete.conf": @{ @"fr" : FR(@"Supprimer ce conteneur ?"), @"en" : @"Delete this container?", @"es" : @"¿Eliminar este contenedor?", @"de" : @"Diesen Container löschen?", @"it" : @"Eliminare questo contenitore?", @"pt" : @"Excluir este contêiner?" },
            @"device.iosFmt"    : @{ @"fr" : FR(@"iOS %@%@"), @"en" : @"iOS %@%@", @"es" : @"iOS %@%@", @"de" : @"iOS %@%@", @"it" : @"iOS %@%@", @"pt" : @"iOS %@%@" },
            @"device.iosReal"   : @{ @"fr" : FR(@"iOS : version réelle (non forcée)"), @"en" : @"iOS: real version (not forced)", @"es" : @"iOS: versión real (no forzada)", @"de" : @"iOS: echte Version (nicht erzwungen)", @"it" : @"iOS: versione reale (non forzata)", @"pt" : @"iOS: versão real (não forçada)" },
            @"device.identFmt"  : @{ @"fr" : FR(@"Identifiant : %@"), @"en" : @"Identifier: %@", @"es" : @"Identificador: %@", @"de" : @"Kennung: %@", @"it" : @"Identificatore: %@", @"pt" : @"Identificador: %@" },
            @"device.modelFmt"  : @{ @"fr" : FR(@"N° de modèle : %@"), @"en" : @"Model number: %@", @"es" : @"N.º de modelo: %@", @"de" : @"Modellnummer: %@", @"it" : @"N.º modello: %@", @"pt" : @"N.º do modelo: %@" },
            @"device.serialFmt" : @{ @"fr" : FR(@"N° de série : %@"), @"en" : @"Serial number: %@", @"es" : @"N.º de serie: %@", @"de" : @"Seriennummer: %@", @"it" : @"N.º di serie: %@", @"pt" : @"N.º de série: %@" },

            // ---- Création / édition ----
            @"create.title.new" : @{ @"fr" : FR(@"Créer un conteneur"), @"en" : @"Create a container", @"es" : @"Crear un contenedor", @"de" : @"Container erstellen", @"it" : @"Crea un contenitore", @"pt" : @"Criar um contêiner" },
            @"create.title.edit": @{ @"fr" : FR(@"Modifier le conteneur"), @"en" : @"Edit container", @"es" : @"Editar contenedor", @"de" : @"Container bearbeiten", @"it" : @"Modifica contenitore", @"pt" : @"Editar contêiner" },
            @"create.name"      : @{ @"fr" : FR(@"Nom du conteneur"), @"en" : @"Container name", @"es" : @"Nombre del contenedor", @"de" : @"Containername", @"it" : @"Nome contenitore", @"pt" : @"Nome do contêiner" },
            @"create.name.ph"   : @{ @"fr" : FR(@"ex : Perso"), @"en" : @"e.g. Personal", @"es" : @"ej.: Personal", @"de" : @"z. B. Persönlich", @"it" : @"es.: Personale", @"pt" : @"ex.: Pessoal" },
            @"create.model"     : @{ @"fr" : FR(@"Modèle d'appareil"), @"en" : @"Device model", @"es" : @"Modelo de dispositivo", @"de" : @"Gerätemodell", @"it" : @"Modello dispositivo", @"pt" : @"Modelo do dispositivo" },
            @"create.ios"       : @{ @"fr" : FR(@"Version iOS"), @"en" : @"iOS version", @"es" : @"Versión de iOS", @"de" : @"iOS-Version", @"it" : @"Versione iOS", @"pt" : @"Versão do iOS" },
            @"create.save"      : @{ @"fr" : FR(@"Enregistrer"), @"en" : @"Save", @"es" : @"Guardar", @"de" : @"Speichern", @"it" : @"Salva", @"pt" : @"Salvar" },
            @"create.footer"    : @{ @"fr" : FR(@"Chaque conteneur est un téléphone isolé et répond ces informations à Instagram."), @"en" : @"Each container is an isolated phone and answers this information to Instagram.", @"es" : @"Cada contenedor es un teléfono aislado y responde esta información a Instagram.", @"de" : @"Jeder Container ist ein isoliertes Telefon und antwortet Instagram mit diesen Informationen.", @"it" : @"Ogni contenitore è un telefono isolato e risponde queste informazioni a Instagram.", @"pt" : @"Cada contêiner é um telefone isolado e responde essas informações ao Instagram." },

            // ---- Auto-swipe ----
            @"swipe.title"      : @{ @"fr" : FR(@"Auto-swipe"), @"en" : @"Auto-swipe", @"es" : @"Auto-swipe", @"de" : @"Auto-Swipe", @"it" : @"Auto-swipe", @"pt" : @"Auto-swipe" },
            @"swipe.method"     : @{ @"fr" : FR(@"Méthode"), @"en" : @"Method", @"es" : @"Método", @"de" : @"Methode", @"it" : @"Metodo", @"pt" : @"Método" },
            @"swipe.buttons"    : @{ @"fr" : FR(@"Boutons (X / ♥)"), @"en" : @"Buttons (X / ♥)", @"es" : @"Botones (X / ♥)", @"de" : @"Tasten (X / ♥)", @"it" : @"Pulsanti (X / ♥)", @"pt" : @"Botões (X / ♥)" },
            @"swipe.gestures"   : @{ @"fr" : FR(@"Gestes du doigt"), @"en" : @"Finger gestures", @"es" : @"Gestos con el dedo", @"de" : @"Fingergesten", @"it" : @"Gesti del dito", @"pt" : @"Gestos com o dedo" },
            @"swipe.count"      : @{ @"fr" : FR(@"Nombre de swipes"), @"en" : @"Number of swipes", @"es" : @"Número de swipes", @"de" : @"Anzahl Swipes", @"it" : @"Numero di swipe", @"pt" : @"Número de swipes" },
            @"swipe.count.0"    : @{ @"fr" : FR(@"0 = illimité"), @"en" : @"0 = unlimited", @"es" : @"0 = ilimitado", @"de" : @"0 = unbegrenzt", @"it" : @"0 = illimitato", @"pt" : @"0 = ilimitado" },
            @"swipe.like.pct"   : @{ @"fr" : FR(@"Like %"), @"en" : @"Like %", @"es" : @"% Me gusta", @"de" : @"Like %", @"it" : @"% Mi piace", @"pt" : @"% Curta" },
            @"swipe.delays"     : @{ @"fr" : FR(@"Délais (s)"), @"en" : @"Delays (s)", @"es" : @"Intervalos (s)", @"de" : @"Verzögerung (s)", @"it" : @"Intervalli (s)", @"pt" : @"Intervalos (s)" },
            @"swipe.start"      : @{ @"fr" : FR(@"Démarrer les swipes"), @"en" : @"Start swiping", @"es" : @"Empezar a deslizar", @"de" : @"Swipen starten", @"it" : @"Avvia swipe", @"pt" : @"Começar a deslizar" },
            @"swipe.messages"   : @{ @"fr" : FR(@"Messages automatiques"), @"en" : @"Automatic messages", @"es" : @"Mensajes automáticos", @"de" : @"Automatische Nachrichten", @"it" : @"Messaggi automatici", @"pt" : @"Mensagens automáticas" },
            @"swipe.ph"         : @{ @"fr" : FR(@"Une phrase par ligne"), @"en" : @"One phrase per line", @"es" : @"Una frase por línea", @"de" : @"Ein Satz pro Zeile", @"it" : @"Una frase per riga", @"pt" : @"Uma frase por linha" },
            @"swipe.msgSection" : @{ @"fr" : FR(@"Phrases envoyées sur un match"), @"en" : @"Messages sent on a match", @"es" : @"Frases enviadas en un match", @"de" : @"Bei einem Match gesendete Sätze", @"it" : @"Frasi inviate su un match", @"pt" : @"Frases enviadas em um match" },
            @"swipe.msgHint"    : @{ @"fr" : FR(@"Une phrase par ligne. À chaque match, le bot en envoie une au hasard. Laisse vide pour liker sans écrire."), @"en" : @"One phrase per line. On each match the bot sends one at random. Leave empty to like without writing.", @"es" : @"Una frase por línea. En cada match el bot envía una al azar. Déjalo vacío para dar like sin escribir.", @"de" : @"Ein Satz pro Zeile. Bei jedem Match sendet der Bot zufällig einen. Leer lassen, um ohne Text zu liken.", @"it" : @"Una frase per riga. A ogni match il bot ne invia una a caso. Lascia vuoto per mettere mi piace senza scrivere.", @"pt" : @"Uma frase por linha. A cada match o bot envia uma aleatória. Deixe vazio para curtir sem escrever." },
            @"swipe.params"     : @{ @"fr" : FR(@"Paramètres de swipe"), @"en" : @"Swipe settings", @"es" : @"Parámetros de swipe", @"de" : @"Swipe-Einstellungen", @"it" : @"Parametri di swipe", @"pt" : @"Parâmetros de swipe" },
            @"swipe.likeLabel"  : @{ @"fr" : FR(@"% de like (droite)"), @"en" : @"% like (right)", @"es" : @"% Me gusta (derecha)", @"de" : @"% Like (rechts)", @"it" : @"% Mi piace (destra)", @"pt" : @"% Curta (direita)" },
            @"swipe.min"        : @{ @"fr" : FR(@"Délai min entre actions (s)"), @"en" : @"Min delay between actions (s)", @"es" : @"Intervalo mínimo entre acciones (s)", @"de" : @"Mindestverzögerung zwischen Aktionen (s)", @"it" : @"Intervallo minimo tra azioni (s)", @"pt" : @"Intervalo mínimo entre ações (s)" },
            @"swipe.max"        : @{ @"fr" : FR(@"Délai max entre actions (s)"), @"en" : @"Max delay between actions (s)", @"es" : @"Intervalo máximo entre acciones (s)", @"de" : @"Maximalverzögerung zwischen Aktionen (s)", @"it" : @"Intervallo massimo tra azioni (s)", @"pt" : @"Intervalo máximo entre ações (s)" },
            @"swipe.detectHint" : @{ @"fr" : FR(@"Détection best-effort : le bot agit sur l'UI de Instagram (like/dislike + popup « match »). Selon la version de Instagram, un réglage sur l'appareil peut être nécessaire."), @"en" : @"Best-effort detection: the bot acts on Instagram's UI (like/dislike + match popup). Depending on the Instagram version, a device setting may be required.", @"es" : @"Detección de mejor esfuerzo: el bot actúa sobre la UI de Instagram (like/dislike + popup de match). Según la versión de Instagram, puede ser necesario un ajuste.", @"de" : @"Best-effort-Erkennung: Der Bot agiert auf der Instagram-UI (Like/Dislike + Match-Popup). Je nach Instagram-Version kann eine Geräteeinstellung nötig sein.", @"it" : @"Rilevamento best-effort: il bot agisce sull'UI di Instagram (like/dislike + popup match). A seconda della versione di Instagram potrebbe servire un'impostazione.", @"pt" : @"Detecção best-effort: o bot age na UI do Instagram (like/dislike + popup de match). Conforme a versão do Instagram, pode ser necessária uma configuração." },
            @"swipe.stop"       : @{ @"fr" : FR(@"Arrêter l'auto-swipe"), @"en" : @"Stop auto-swipe", @"es" : @"Detener el auto-swipe", @"de" : @"Auto-Swipe stoppen", @"it" : @"Ferma l'auto-swipe", @"pt" : @"Parar o auto-swipe" },

            // ---- GPS ----
            @"gps.title"        : @{ @"fr" : FR(@"Localisation GPS"), @"en" : @"GPS Location", @"es" : @"Ubicación GPS", @"de" : @"GPS-Standort", @"it" : @"Posizione GPS", @"pt" : @"Localização GPS" },
            @"gps.search"       : @{ @"fr" : FR(@"Rechercher une ville…"), @"en" : @"Search a city…", @"es" : @"Buscar una ciudad…", @"de" : @"Stadt suchen…", @"it" : @"Cerca una città…", @"pt" : @"Buscar uma cidade…" },
            @"gps.activate"     : @{ @"fr" : FR(@"Activer cette position"), @"en" : @"Activate this location", @"es" : @"Activar esta ubicación", @"de" : @"Diese Position aktivieren", @"it" : @"Attiva questa posizione", @"pt" : @"Ativar esta localização" },
            @"gps.clear"        : @{ @"fr" : FR(@"Effacer"), @"en" : @"Clear", @"es" : @"Borrar", @"de" : @"Löschen", @"it" : @"Cancella", @"pt" : @"Limpar" },
            @"gps.pin"          : @{ @"fr" : FR(@"Position choisie"), @"en" : @"Chosen position", @"es" : @"Posición elegida", @"de" : @"Gewählter Ort", @"it" : @"Posizione scelta", @"pt" : @"Posição escolhida" },
            @"gps.savefail.t"   : @{ @"fr" : FR(@"Échec de l'enregistrement"), @"en" : @"Save failed", @"es" : @"Error al guardar", @"de" : @"Speichern fehlgeschlagen", @"it" : @"Salvataggio non riuscito", @"pt" : @"Falha ao salvar" },
            @"gps.savefail.m"   : @{ @"fr" : FR(@"La localisation n'a pas pu être enregistrée (écriture disque échouée). Réessaie."), @"en" : @"The location could not be saved (disk write failed). Try again.", @"es" : @"No se pudo guardar la ubicación (error de escritura). Inténtalo de nuevo.", @"de" : @"Der Standort konnte nicht gespeichert werden (Schreibfehler). Versuch es erneut.", @"it" : @"Impossibile salvare la posizione (errore di scrittura). Riprova.", @"pt" : @"Não foi possível salvar a localização (falha de gravação). Tente novamente." },

            // ---- Comptes ----
            @"acct.title"       : @{ @"fr" : FR(@"Comptes"), @"en" : @"Accounts", @"es" : @"Cuentas", @"de" : @"Konten", @"it" : @"Account", @"pt" : @"Contas" },
            @"acct.saved"       : @{ @"fr" : FR(@"Comptes sauvegardés"), @"en" : @"Saved accounts", @"es" : @"Cuentas guardadas", @"de" : @"Gespeicherte Konten", @"it" : @"Account salvati", @"pt" : @"Contas salvas" },
            @"acct.add"         : @{ @"fr" : FR(@"Ajouter le compte courant"), @"en" : @"Add current account", @"es" : @"Agregar cuenta actual", @"de" : @"Aktuelles Konto hinzufügen", @"it" : @"Aggiungi account attuale", @"pt" : @"Adicionar conta atual" },
            @"acct.remove"      : @{ @"fr" : FR(@"Supprimer un compte"), @"en" : @"Remove an account", @"es" : @"Eliminar una cuenta", @"de" : @"Konto entfernen", @"it" : @"Rimuovi un account", @"pt" : @"Remover uma conta" },
            @"acct.save.title"  : @{ @"fr" : FR(@"Ajouter un compte"), @"en" : @"Add an account", @"es" : @"Agregar cuenta", @"de" : @"Konto hinzufügen", @"it" : @"Aggiungi account", @"pt" : @"Adicionar conta" },
            @"acct.save.msg"    : @{ @"fr" : FR(@"Identifiant du compte courant à sauvegarder"), @"en" : @"Identifier of the current account to save", @"es" : @"Identificador de la cuenta actual a guardar", @"de" : @"Kennung des aktuellen Kontos zum Speichern", @"it" : @"Identificativo dell'account da salvare", @"pt" : @"Identificador da conta atual a salvar" },
            @"acct.ph"          : @{ @"fr" : FR(@"ex : mon.pseudo"), @"en" : @"e.g. my.username", @"es" : @"ej.: mi.usuario", @"de" : @"z. B. mein.benutzername", @"it" : @"es.: mio.username", @"pt" : @"ex.: meu.usuario" },
            @"acct.pick.title"  : @{ @"fr" : FR(@"Sélectionne un compte à (ré)injecter"), @"en" : @"Select an account to (re)inject", @"es" : @"Selecciona una cuenta para (re)inyectar", @"de" : @"Konto zum (erneuten) Injizieren wählen", @"it" : @"Seleziona un account da (ri)iniettare", @"pt" : @"Selecione uma conta para (re)injetar" },
            @"acct.none"        : @{ @"fr" : FR(@"(aucun compte sauvegardé)"), @"en" : @"(no saved account)", @"es" : @"(ninguna cuenta guardada)", @"de" : @"(kein gespeichertes Konto)", @"it" : @"(nessun account salvato)", @"pt" : @"(nenhuma conta salva)" },
        };
    });
    return t;
}

// Langue cible courante, calculée à la 1re lecture puis mise en cache.
NSString *IVLCurrentLanguage(void) {
    static NSString *gLang;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *lang = nil;
        NSString *ov = [[NSUserDefaults standardUserDefaults] stringForKey:@"IVLOverrideLanguage"];
        if (ov.length) {
            lang = [[ov componentsSeparatedByString:@"-"] firstObject];
        } else {
            // Langue de l'APP du conteneur ; sinon langue système du téléphone.
            NSString *appLang = [IVLocaleSpoof deviceLanguage];
            if (appLang.length) lang = [[appLang componentsSeparatedByString:@"-"] firstObject];
            else {
                NSString *sys = [NSLocale preferredLanguages].firstObject;
                if (sys.length) lang = [[sys componentsSeparatedByString:@"-"] firstObject];
            }
        }
        lang = [lang lowercaseString];
        // Valide contre les langues réellement traduites dans la table.
        static NSSet *known;
        static dispatch_once_t ok;
        dispatch_once(&ok, ^{
            known = [NSSet setWithArray:@[@"fr", @"en", @"es", @"de", @"it", @"pt"]];
        });
        if (!(lang.length && [known containsObject:lang])) lang = nil; // → repli FR
        gLang = lang;
    });
    return gLang;
}

void IVLSetOverrideLanguage(NSString *_Nullable lang) {
    // Persiste l'override ; il est relu à chaque nouvelle exécution.
    [[NSUserDefaults standardUserDefaults] setObject:lang ?: @"" forKey:@"IVLOverrideLanguage"];
}

NSString *IVLL(NSString *key, NSString *fallbackFR) {
    if (!key.length) return fallbackFR ?: @"";
    NSDictionary<NSString *, NSString *> *row = IVL10nTable()[key];
    if (!row) return fallbackFR ?: key;
    NSString *lang = IVLCurrentLanguage();
    // Langue cible d'abord, sinon français (source), sinon clé.
    NSString *hit = row[lang];
    if (!hit.length) hit = row[@"fr"];
    if (!hit.length) hit = fallbackFR ?: key;
    return hit;
}
