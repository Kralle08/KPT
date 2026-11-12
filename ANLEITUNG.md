# KPT-App einrichten

Du brauchst etwa 45 Minuten und zwei kostenlose Konten: **GitHub** (dort liegt die App) und **Supabase** (dort liegen die Daten). Programmieren musst du nichts.

Hinweis: Die Namen der Menüpunkte bei GitHub und Supabase ändern sich gelegentlich leicht. Wenn du etwas nicht findest, schick Claude einen Screenshot.

## Schritt 1: App bei GitHub ablegen

1. Auf <https://github.com> ein Konto anlegen oder anmelden.
2. Oben rechts **+** → **New repository**. Name: `kpt`, Sichtbarkeit **Public**, dann **Create repository**.
3. Auf **uploading an existing file** klicken, den gesamten Inhalt des entpackten Ordners hineinziehen (den Inhalt, nicht den Ordner selbst) und **Commit changes** klicken. Am besten am PC oder Mac erledigen.
4. Prüfen, ob es in GitHub den Ordner `.github/workflows` gibt. Er ist auf dem Rechner oft unsichtbar und fehlt dann. Falls er fehlt: **Add file** → **Create new file**, als Namen `.github/workflows/erinnerungen.yml` eintippen, den Inhalt der gleichnamigen Datei hineinkopieren und speichern.
5. **Settings** → **Pages** → Source: **Deploy from a branch**, Branch **main**, Ordner **/ (root)** → **Save**.
6. Nach ein bis zwei Minuten steht dort die Adresse eurer App, z. B. `https://dein-name.github.io/kpt/`. Sie läuft jetzt im Demo-Modus mit Beispieldaten.

## Schritt 2: Datenbank anlegen

1. Auf <https://supabase.com> anmelden (am einfachsten mit **Continue with GitHub**).
2. **New project**: Name `kpt`, ein Datenbank-Passwort vergeben und aufheben, Region **Central EU (Frankfurt)**.
3. Links **SQL Editor** öffnen, den gesamten Inhalt der Datei `supabase/schema.sql` einfügen.
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

## Schritt 6: Erinnerungen einrichten

Die Erinnerungen verschickt GitHub automatisch: mittwochs gegen 15 Uhr an alle, die sich noch nicht an- oder abgemeldet haben, und donnerstags gegen 7 Uhr an die Köche mit der Zahl der Portionen (in der Sommerzeit jeweils eine Stunde später).

1. In GitHub im Repository: **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
2. Diese fünf Einträge anlegen, Namen genau so schreiben:

| Name | Wert |
|---|---|
| `SUPABASE_URL` | die Project URL aus Schritt 4 |
| `SUPABASE_SECRET_KEY` | Supabase → **Project Settings** → **API Keys** → **Secret key** (bei älteren Projekten „service_role“) |
| `VAPID_PUBLIC_KEY` | aus der Datei `VAPID-PRIVAT.txt` |
| `VAPID_PRIVATE_KEY` | aus der Datei `VAPID-PRIVAT.txt` |
| `VAPID_CONTACT` | deine E-Mail-Adresse |

3. Der Secret key und die Datei `VAPID-PRIVAT.txt` sind geheim. Sie gehören nur in diese Secrets, **nicht** in die Dateien im Repository.
4. Test: In der App im Profil **Erinnerungen** einschalten. Dann in GitHub **Actions** → **Erinnerungen** → **Run workflow** → Modus `test` → **Run workflow**. Nach etwa einer Minute kommt eine Probe-Mitteilung.

## App auf den Startbildschirm legen

- **iPhone (Safari):** Teilen-Symbol → **Zum Home-Bildschirm**.
- **Android (Chrome):** Menü mit den drei Punkten → **Zum Startbildschirm hinzufügen** bzw. **App installieren**.

Auf dem iPhone funktionieren die Erinnerungen nur, wenn die App auf dem Home-Bildschirm liegt und von dort geöffnet wird.

## Gut zu wissen

- **Gäste:** Wer angemeldet ist, kann bis Anmeldeschluss bis zu 5 Gäste eintragen. Sie zählen bei den Portionen und in der Kasse bei dem Mitglied, das sie mitbringt.
- **Clubkasse:** Der Koch trägt beim Essen die Einkaufskosten ein. Nach Anmeldeschluss verteilt die App den Betrag auf alle Portionen, der Koch bekommt ihn gutgeschrieben (bei zwei Köchen je zur Hälfte). Oben in der App steht der eigene Stand; ein Tipp darauf zeigt, wer wem wie viel geben sollte. Bezahlt wird außerhalb der App (bar, PayPal, Überweisung) und danach mit **Als bezahlt eintragen** vermerkt.
- **Erinnerungen:** Jedes Mitglied schaltet sie selbst im Profil ein, pro Gerät. GitHub stellt den Zeitplan ab, wenn im Repository 60 Tage lang nichts geändert wurde, und schickt dir vorher eine Mail. Dann unter **Actions** auf **Enable workflow** klicken.

- **Regeln:** An- und Abmelden geht bis Mittwoch 23:59 Uhr. Wer kocht, ist automatisch angemeldet. Bewerten kann ab dem Freitag, wer angemeldet war und nicht selbst gekocht hat. Höchstens zwei Personen kochen pro Freitag.
- **Passwort vergessen:** Ein Admin öffnet oben rechts das Profil → beim Mitglied **Neues Passwort** → setzt eines und gibt es persönlich weiter. Es gibt bewusst keine „Passwort vergessen“-Mail.
- **Mitglied verlässt den Club:** Profil → Mitglied **Pausieren**. Die Person kommt nicht mehr hinein, ihre Kochtage und Bewertungen bleiben in der Statistik.
- **Mehr Mitglieder:** Die App hat keine Obergrenze. Die kostenlosen Tarife reichen für einen Club dieser Größe nach meinem Stand über Jahre.
- **Pause bei Nichtnutzung:** Supabase pausiert kostenlose Projekte, wenn sie etwa eine Woche gar nicht genutzt werden (z. B. in den Betriebsferien). Dann bei Supabase anmelden und **Restore project** klicken, die Daten bleiben erhalten.
- **Änderungen an Texten, Regeln oder Aussehen:** Claude sagen, was anders sein soll. Du bekommst eine neue `index.html` und lädst sie in GitHub hoch.
- **Nicht getestet:** Der Push-Versand und der Betrieb mit echter Datenbank konnten vorab nicht live geprüft werden. Bitte Schritt 6 Punkt 4 wirklich ausprobieren.
