CREATE TABLE tournaments (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  starts_at timestamp NOT NULL,
  location text NOT NULL,
  buy_in integer NOT NULL,
  re_entry integer NOT NULL,
  prize_pool integer NOT NULL,
  rating_pool integer NOT NULL,
  rating_series_month text,
  entries_count integer,
  profile text NOT NULL,
  late_registration_ends_at timestamp,
  add_on_enabled boolean NOT NULL,
  add_on_price integer NOT NULL,
  add_on_chips integer NOT NULL,
  max_participants integer NOT NULL,
  status text NOT NULL,
  allow_cancellation boolean NOT NULL,
  created_date date NOT NULL
);

CREATE TABLE players (
  player_id text PRIMARY KEY,
  display_name text NOT NULL,
  rating_points integer NOT NULL,
  knockouts integer NOT NULL,
  tournaments_played integer NOT NULL,
  tournament_wins integer NOT NULL
);

CREATE TABLE registrations (
  registration_id text PRIMARY KEY,
  player_id text NOT NULL REFERENCES players(player_id),
  tournament_id text NOT NULL REFERENCES tournaments(id),
  status text NOT NULL,
  live_status text NOT NULL,
  finish_place integer,
  entry_number integer NOT NULL,
  add_on_count integer NOT NULL,
  checked_in boolean NOT NULL,
  created_date date NOT NULL
);

CREATE TABLE rating_results (
  tournament_id text NOT NULL REFERENCES tournaments(id),
  player_id text NOT NULL REFERENCES players(player_id),
  place integer NOT NULL,
  percent integer NOT NULL,
  points integer NOT NULL,
  knockouts integer NOT NULL,
  created_date date NOT NULL,
  PRIMARY KEY (tournament_id, player_id),
  UNIQUE (tournament_id, place)
);

CREATE TABLE knockouts (
  knockout_id text PRIMARY KEY,
  tournament_id text NOT NULL REFERENCES tournaments(id),
  eliminated_registration_id text NOT NULL REFERENCES registrations(registration_id),
  killer_registration_id text REFERENCES registrations(registration_id),
  created_date date NOT NULL
);
