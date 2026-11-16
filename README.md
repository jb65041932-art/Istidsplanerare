# Istidsplanerare

Veckoschema för istiderna i ishallen. Alla kan läsa schemat utan inloggning. Den som är upplagd som admin loggar in och ändrar med drag and drop.

## Delar

| Del | Var | Kommentar |
|:--|:--|:--|
| Sidan | `index.html` | En enda fil, inget byggsteg. Publiceras på Vercel. |
| Databasuppgifter | `config.js` | Adress och publik nyckel till Supabase. |
| Databasen | `supabase/schema.sql` | Tabeller, regler och statistikfunktion. |

## Behörighet

- Tabellerna `teams`, `bookings` och `settings` kan läsas av alla.
- Bara inloggade med bekräftad e-post som finns i tabellen `admin_emails` kan ändra.
- Ge en ny person redigeringsrätt genom att lägga till adressen (med små bokstäver) i `admin_emails`. Personen skapar sedan själv sitt konto via Logga in på sidan.

## Kör lokalt

Öppna mappen med valfri statisk webbserver, till exempel `npx serve .`.
