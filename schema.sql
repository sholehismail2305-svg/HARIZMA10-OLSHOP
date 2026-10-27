-- HARIZMA ONLINE: skema database. Jalankan seluruhnya di Supabase > SQL Editor.
-- Setiap tabel punya user_id (pemilik) dan hanya bisa diakses pemiliknya (RLS).

create table usaha (            -- profil usaha (1 baris per pemilik)
  user_id uuid primary key default auth.uid() references auth.users on delete cascade,
  nama text not null, alamat text, kontak text);

create table produk (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  kode text not null,                         -- kode produk (unik)
  nama text not null,
  harga_beli numeric not null default 0 check (harga_beli >= 0),
  harga_jual numeric not null default 0 check (harga_jual >= 0),
  stok int not null default 0 check (stok >= 0),   -- stok saat ini
  stok_min int not null default 0,                 -- batas peringatan stok
  kadaluarsa date, keterangan text,
  created_at timestamptz not null default now(),
  unique (user_id, kode));

create table pelanggan (        -- minimarket langganan
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  nama_toko text not null, pemilik text, alamat text, telepon text, keterangan text,
  created_at timestamptz not null default now());

create table pengiriman (       -- kepala nota
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  pelanggan_id uuid not null references pelanggan on delete restrict,
  tanggal date not null default current_date,
  total numeric not null default 0,   -- total penjualan
  hpp numeric not null default 0,     -- harga pokok penjualan
  status text not null default 'piutang' check (status in ('lunas','piutang')),
  jatuh_tempo date,
  created_at timestamptz not null default now());

create table pengiriman_item (  -- isi nota (nama & harga disalin agar riwayat tetap utuh)
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  pengiriman_id uuid not null references pengiriman on delete cascade,
  produk_id uuid references produk on delete set null,
  nama text not null, qty int not null check (qty > 0),
  harga_jual numeric not null, harga_beli numeric not null,
  created_at timestamptz not null default now());

create table pembelian (        -- belanja stok = pengeluaran
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  produk_id uuid references produk on delete set null,
  nama text, tanggal date not null default current_date,
  qty int not null check (qty > 0), harga_beli numeric not null check (harga_beli >= 0),
  total numeric not null, keterangan text,
  created_at timestamptz not null default now());

create table pembayaran (       -- uang masuk dari pelanggan = pemasukan
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  pengiriman_id uuid not null references pengiriman on delete cascade,
  tanggal date not null default current_date,
  jumlah numeric not null check (jumlah > 0),
  created_at timestamptz not null default now());

-- Keamanan: aktifkan RLS + kebijakan "hanya pemilik" + indeks
do $$ declare t text; begin
  foreach t in array array['usaha','produk','pelanggan','pengiriman','pengiriman_item','pembelian','pembayaran'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy pemilik on %I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;
create index on produk(user_id); create index on pelanggan(user_id);
create index on pengiriman(user_id, tanggal); create index on pengiriman(pelanggan_id);
create index on pengiriman_item(pengiriman_id); create index on pembelian(user_id, tanggal);
create index on pembayaran(pengiriman_id); create index on pembayaran(user_id, tanggal);

-- Simpan nota: kurangi stok, hitung total & HPP, catat pembayaran bila LUNAS (satu transaksi atomik)
create function kirim_barang(p_pelanggan uuid, p_tanggal date, p_status text, p_jatuh_tempo date, p_items jsonb)
returns uuid language plpgsql set search_path = public as $$
declare v_id uuid; v_tot numeric := 0; v_hpp numeric := 0; it jsonb; pr produk; q int;
begin
  insert into pengiriman(pelanggan_id, tanggal, status, jatuh_tempo) values (p_pelanggan, p_tanggal, p_status, p_jatuh_tempo) returning id into v_id;
  for it in select value from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    select * into pr from produk where id = (it->>'produk_id')::uuid for update;
    if not found then raise exception 'Produk tidak ditemukan'; end if;
    if pr.stok < q then raise exception 'Stok % tidak cukup (sisa %)', pr.nama, pr.stok; end if;
    update produk set stok = stok - q where id = pr.id;
    insert into pengiriman_item(pengiriman_id, produk_id, nama, qty, harga_jual, harga_beli) values (v_id, pr.id, pr.nama, q, pr.harga_jual, pr.harga_beli);
    v_tot := v_tot + pr.harga_jual * q; v_hpp := v_hpp + pr.harga_beli * q;
  end loop;
  update pengiriman set total = v_tot, hpp = v_hpp where id = v_id;
  if p_status = 'lunas' then insert into pembayaran(pengiriman_id, tanggal, jumlah) values (v_id, p_tanggal, v_tot); end if;
  return v_id;
end $$;

-- Beli stok: tambah stok, perbarui harga beli, catat pengeluaran
create function beli_stok(p_produk uuid, p_tanggal date, p_qty int, p_harga numeric, p_ket text)
returns void language plpgsql set search_path = public as $$
declare pr produk;
begin
  select * into pr from produk where id = p_produk for update;
  if not found then raise exception 'Produk tidak ditemukan'; end if;
  update produk set stok = stok + p_qty, harga_beli = p_harga where id = p_produk;
  insert into pembelian(produk_id, nama, tanggal, qty, harga_beli, total, keterangan) values (p_produk, pr.nama, p_tanggal, p_qty, p_harga, p_qty * p_harga, p_ket);
end $$;

-- Catat pembayaran piutang; status otomatis LUNAS bila terbayar penuh
create function catat_pembayaran(p_kirim uuid, p_tanggal date, p_jumlah numeric)
returns void language plpgsql set search_path = public as $$
declare k pengiriman; sudah numeric;
begin
  select * into k from pengiriman where id = p_kirim for update;
  if not found then raise exception 'Transaksi tidak ditemukan'; end if;
  select coalesce(sum(jumlah), 0) into sudah from pembayaran where pengiriman_id = p_kirim;
  if p_jumlah > k.total - sudah then raise exception 'Jumlah melebihi sisa piutang'; end if;
  insert into pembayaran(pengiriman_id, tanggal, jumlah) values (p_kirim, p_tanggal, p_jumlah);
  if sudah + p_jumlah >= k.total then update pengiriman set status = 'lunas' where id = p_kirim; end if;
end $$;
