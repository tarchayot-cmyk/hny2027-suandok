# Christmas Wish Tree · HNY2027 Suandok

Make a Wish. Become a Santa. Spread the Joy.

Static site (index.html + images) on Vercel, data on Supabase (project `loykrathong-online`).

- Login: nickname + room + 4-digit PIN (Supabase anonymous auth + `login_profile` / `register_profile` RPC)
- All state changes go through Postgres functions (claim is atomic; RLS blocks direct table access)
- Wishes open until 25 Dec 2026, delivery until 31 Dec 2026 (`app_settings`)
