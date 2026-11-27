# KPT-App einrichten

Du brauchst etwa 45 Minuten und zwei kostenlose Konten: **GitHub** (dort liegt die App) und **Supabase** (dort liegen die Daten). Programmieren musst du nichts.

Hinweis: Die Namen der Menüpunkte bei GitHub und Supabase ändern sich gelegentlich leicht. Wenn du etwas nicht findest, schick Claude einen Screenshot.

## Schritt 1: App bei GitHub ablegen

1. Auf <https://github.com> ein Konto anlegen oder anmelden.
2. Oben rechts **+** → **New repository**. Name: `kpt`, Sichtbarkeit **Public**, dann **Create repository**.
3. Auf **uploading an existing file** klicken, den Inhalt des entpackten Ordners hineinziehen (den Inhalt, nicht den Ordner selbst; die Ordner `supabase-funktion` und die Datei `schema.sql` brauchst du dort nicht) und **Commit changes** klicken. Am besten am PC oder Mac erledigen.
4. **Settings** → **Pages** → Source: **Deploy from a branch**, Branch **main**, Ordner **/ (root)** → **Save**.
5. Nach ein bis zwei Minuten steht dort die Adresse eurer App, z. B. `https://dein-name.github.io/kpt/`. Sie läuft jetzt im Demo-Modus mit Beispieldaten.

## Schritt 2: Datenbank anlegen

1. Auf <https://supabase.com> anmelden (am einfachsten mit **Continue with GitHub**).
2. **New project**: Name `kpt`, ein Datenbank-Passwort vergeben und aufheben, Region **Central EU (Frankfurt)**.
3. Links **SQL Editor** öffnen, den gesamten Inhalt der Datei `schema.sql` einfügen.
4. In der Zeile mit `'KOCHLOEFFEL'` das Wort durch euren eigenen Einladungscode ersetzen (lässt sich später in der App ändern).
5. **Run** klicken. Es erscheint „Success. No rows returned“.

## Schritt 3: Bestätigungs-Mail abschalten

Sonst müsste jedes Mitglied erst eine Mail bestätigen, und Supabase verschickt kostenlos nur sehr wenige Mails.

1. **Authentication** → **Sign In / Providers** → **Email**.
2. **Confirm email** ausschalten → **Save**.

Der Einladungscode sorgt dafür, dass trotzdem nur Clubmitglieder hineinkommen.

## Schritt 4: App mit der Datenbank verbinden

1. In Supabase unter **Project Settings** → **Data API** die **Project URL** kopieren (sieht aus wie `https://abcd1234.supabase.co`).
2. Unter **Project Settings** → **API Keys** den **Publishable key** kopieren (bei älteren Projekten heißt er „anon public“). Dieser Schlüssel darf öffentlich sein. Den „Secret key“ nie verwenden.
3. In GitHub die Datei `config.js` öffnen → Stift-Symbol → beide Werte zwischen die Anführungszeichen eintragen → **Commit changes**.
4. Nach ein bis zwei Minuten zeigt die App statt der Demo die Anmeldeseite.

## Schritt 5: Club starten

1. Registriere dich als Erster. **Wer zuerst beitritt, ist Admin.**
2. Schick den anderen die Adresse der App und den Einladungscode.
3. Jedes Mitglied tippt auf **Neu registrieren**, wählt E-Mail und Passwort und gibt danach Namen und Einladungscode ein.

## Schritt 6: Mitteilungen einrichten

Die Datenbank prüft jede Minute, ob etwas zu verschicken ist: Mittwoch 15 Uhr die Erinnerung an alle ohne Antwort, Donnerstag 7 Uhr die Portionen an die Köche, Donnerstag 18:05 Uhr den Endstand, Freitag 18 Uhr die Erinnerung zum Bewerten an alle, die mitgegessen und noch nicht bewertet haben, dazu neue Chatnachrichten und (wer will) neue Fotos. Verschickt wird über eine kleine Supabase-Funktion namens `push`.

1. **Schlüssel erzeugen:** Die Datei `VAPID-PRIVAT.txt` (von Claude) enthält einen öffentlichen und einen privaten Schlüssel. Der öffentliche steht schon in `config.js`.
2. **Funktion anlegen:** Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**. Name: `push`. Den gesamten Inhalt von `supabase-funktion/index.ts` einfügen und **Deploy function** klicken.
3. **Prüfung abschalten:** Bei der Funktion `push` → **Details** → **Verify JWT** (bzw. „Enforce JWT verification“) ausschalten → speichern. Die Funktion schützt sich selbst mit einem eigenen Passwort.
4. **Secrets eintragen:** **Edge Functions** → **Secrets**: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_CONTACT` (deine E-Mail) und `KPT_SECRET` (ein langes, zufälliges Passwort).
5. **Datenbank verbinden:** Im **SQL Editor** ausführen (Projekt-Adresse und dasselbe Passwort wie bei `KPT_SECRET`):
   ```sql
   update public.push_config set function_url = 'https://DEIN-PROJEKT.supabase.co/functions/v1/push', secret = 'DEIN-PASSWORT';
   ```
6. **Testen:** In der App im Profil die Mitteilungen auf diesem Gerät einschalten. Dann im SQL Editor `select public.kpt_test_push();` ausführen. Nach wenigen Sekunden kommt „KPT: Probe-Mitteilung“.

Auf dem iPhone funktionieren Mitteilungen nur, wenn die App auf dem Home-Bildschirm liegt und von dort geöffnet wird.

## App auf den Startbildschirm legen

- **iPhone (Safari):** Teilen-Symbol → **Zum Home-Bildschirm**.
- **Android (Chrome):** Menü mit den drei Punkten → **Zum Startbildschirm hinzufügen** bzw. **App installieren**.

Auf dem iPhone funktionieren die Erinnerungen nur, wenn die App auf dem Home-Bildschirm liegt und von dort geöffnet wird.

## Gut zu wissen

- **Frühere Essen nachtragen:** Admins finden im Reiter „Essen“ unten **Früheres Essen nachtragen**. Dort Freitag, Koch, Gericht und die Teilnehmer eintragen. Die Teilnehmer können das Essen danach selbst bewerten, Einkaufskosten zählen in der Kasse mit. Admins können jedes Essen bearbeiten und vergangene Essen löschen.
- **Teilnehmer von Hand eintragen:** Admins können bei jedem Essen in der Detailansicht unter **Teilnehmer ändern** Mitglieder an- oder abmelden, auch nach Anmeldeschluss. Das ist für alle gedacht, die sich nicht selbst angemeldet haben.
- **Goldener Löffel (ab 2027):** Jedes Mitglied kann pro Kalenderjahr einen goldenen Löffel vergeben, für Essen ab dem 1. Januar 2027, jeweils bis zum Donnerstag nach dem Essen. Er braucht eine Begründung (mindestens 20 Zeichen), ist endgültig, zählt im Ranking wie 10 Kochlöffel und erscheint auf der Ehrentafel unter Ranking → Goldene Löffel.
- **Reaktionen auf Fotos:** Unter jedem Foto kann jedes Mitglied 👍, 😋 oder ❤️ setzen und mit einem zweiten Tipp zurücknehmen. Ein Tipp auf das Foto zeigt es groß und darunter, wer wie reagiert hat.
- **Gäste:** Wer angemeldet ist, kann bis Freitag 12 Uhr bis zu 5 Gäste eintragen oder wieder streichen. Sie zählen bei den Portionen und in der Kasse bei dem Mitglied, das sie mitbringt.
- **Clubkasse:** Der Koch trägt beim Essen die Einkaufskosten ein. Nach Anmeldeschluss am Donnerstagabend verteilt die App den Betrag auf alle Portionen, jeder Koch bekommt gutgeschrieben, was er ausgelegt hat. Oben in der App steht der eigene Stand; ein Tipp darauf zeigt alle Kontostände. Im Normalfall gleicht sich die Kasse übers Kochen aus. Wer doch einmal alles glattziehen will (etwa wenn jemand aufhört), klappt **Komplett ausgleichen** auf und sieht, wer wem wie viel geben sollte. Bezahlt wird außerhalb der App (bar, PayPal, Überweisung) und danach mit **Als bezahlt eintragen** vermerkt.
- **Mitteilungen:** Jedes Mitglied schaltet sie im Profil pro Gerät ein und wählt, was es bekommen möchte: Erinnerungen zum Freitag, Chat, Fotos. Kommt nichts an: In Supabase → **Edge Functions** → `push` → **Logs** steht, was verschickt wurde.

- **Regeln:** Bis Mittwoch 23:59 Uhr kann sich jeder frei an- und abmelden. Danach geht bis Donnerstag 18 Uhr nur noch Nachmelden (zusagen), Absagen nicht mehr. Die Zahl der eigenen Gäste lässt sich bis Freitag 12 Uhr ändern, auch nach unten. Nachmeldungen sind mit „nach Mittwoch“ markiert. Wer kocht, ist automatisch angemeldet. Bewerten kann ab Freitag 12:30 Uhr, wer angemeldet war und nicht selbst gekocht hat.
- **Zu zweit kochen:** Höchstens zwei Personen kochen pro Freitag. Die zweite Person tippt beim Essen auf **Mitkochen**. Bewertungen zählen für beide. Bei den Einkaufskosten trägt jeder seinen eigenen Betrag ein und bekommt genau den gutgeschrieben.
- **Passwort vergessen:** Ein Admin öffnet oben rechts das Profil → beim Mitglied **Neues Passwort** → setzt eines und gibt es persönlich weiter. Es gibt bewusst keine „Passwort vergessen“-Mail.
- **Mitglied verlässt den Club:** Profil → Mitglied **Pausieren**. Die Person kommt nicht mehr hinein, ihre Kochtage und Bewertungen bleiben in der Statistik.
- **Mehr Mitglieder:** Die App hat keine Obergrenze. Die kostenlosen Tarife reichen für einen Club dieser Größe nach meinem Stand über Jahre.
- **Pause bei Nichtnutzung:** Supabase pausiert kostenlose Projekte, wenn sie etwa eine Woche gar nicht genutzt werden (z. B. in den Betriebsferien). Dann bei Supabase anmelden und **Restore project** klicken, die Daten bleiben erhalten.
- **Änderungen an Texten, Regeln oder Aussehen:** Claude sagen, was anders sein soll. Du bekommst eine neue `index.html` und lädst sie in GitHub hoch.
- **Nicht getestet:** Der Push-Versand und der Betrieb mit echter Datenbank konnten vorab nicht live geprüft werden. Bitte Schritt 6 Punkt 4 wirklich ausprobieren.
