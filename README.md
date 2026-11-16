# Istidsplanerare

Veckoschema för istiderna i ishallen. Alla kan läsa schemat utan inloggning. Den som är upplagd som admin loggar in och ändrar med drag and drop.

## Delar

| Del | Var | Kommentar |
|:--|:--|:--|
| Sidan | `index.html` | En enda fil, inget byggsteg. Publiceras på Vercel vid varje push till `main`. |
| Databasuppgifter | `config.js` | Adress och publik nyckel till Supabase. |
| Databasen | `supabase/migrations/` | Tabeller, regler och statistikfunktion, i den ordning de har körts. |
| Inbjudningar | `supabase/functions/editors/` | Edge-funktion som listar, bjuder in och tar bort planerare. |

## Hallar

Hallarna ligger i tabellen `rinks`, var och en med egna öppettider. Lagen är gemensamma för alla hallar.

## Behörighet

- Schemat (`rinks`, `teams`, `bookings`) kan läsas av alla.
- Bara inloggade vars e-postadress finns i tabellen `editors` kan ändra.
- En superanvändare (`role = 'super'`) bjuder in planerare under Användare på sidan. Det skapar en engångslänk som superanvändaren skickar vidare. Mottagaren öppnar länken och väljer lösenord.
- Det finns ingen öppen registrering på sidan. En ny superanvändare läggs till direkt i `editors`.

## Kör lokalt

Öppna mappen med valfri statisk webbserver, till exempel `npx serve .`.
