-- solar-system-db schema
-- SQLite. Designed for model-building: orbital + physical + visual properties,
-- normalised across object types (planet / moon / dwarf_planet / asteroid /
-- comet / tno / centaur), with rings as a sibling table.
--
-- Notes:
--   * `objects.id` is a stable string PK (e.g. "planet-earth", "moon-io",
--     "ast-2-pallas") so the rows survive re-imports.
--   * `parent_id` is null for sun-orbiters and set to the planet for moons.
--   * `sources` keeps provenance per (object_id, field).
--   * Everything is normalised so model code can pull just the slice it needs.

PRAGMA foreign_keys = ON;
-- Note: we intentionally don't set journal_mode=WAL here — the DB is published
-- as a single committed file and WAL files are a deployment headache. Default
-- rollback journal is fine; performance is more than adequate for read-mostly
-- workloads at this scale.

----------------------------------------------------------------------
-- Core
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS objects (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    designation     TEXT,                -- e.g. "(2) Pallas", "1P/Halley"
    object_type     TEXT NOT NULL CHECK (object_type IN (
                        'star','planet','moon','dwarf_planet','dwarf_planet_candidate',
                        'asteroid','comet','tno','centaur','trojan','hilda','neo','pha'
                    )),
    parent_id       TEXT REFERENCES objects(id) ON DELETE SET NULL,
    discoverer      TEXT,
    discovery_date  TEXT,                -- ISO 8601 (date or year)
    wikipedia_url   TEXT,
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_objects_type      ON objects(object_type);
CREATE INDEX IF NOT EXISTS idx_objects_parent    ON objects(parent_id);
CREATE INDEX IF NOT EXISTS idx_objects_name      ON objects(name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_objects_design    ON objects(designation);

----------------------------------------------------------------------
-- Classifications (multi-label: an object can be NEO + PHA + Apollo, etc.)
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS classifications (
    object_id   TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    label       TEXT NOT NULL,           -- 'NEO','PHA','Trojan','Hilda','MBA','Centaur','KBO','SDO','Inner','Outer'
    PRIMARY KEY (object_id, label)
);
CREATE INDEX IF NOT EXISTS idx_class_label ON classifications(label);

----------------------------------------------------------------------
-- Orbital elements (heliocentric for sun-orbiters; planet-centric where noted)
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orbital_elements (
    object_id                       TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,
    epoch                           TEXT,        -- JD or ISO 8601
    epoch_jd                        REAL,        -- Julian Date for the elements
    frame                           TEXT,        -- 'J2000' usually
    centre                          TEXT,        -- 'Sun','Earth','Jupiter',...
    semi_major_axis_au              REAL,
    eccentricity                    REAL,
    inclination_deg                 REAL,
    longitude_ascending_node_deg    REAL,
    argument_periapsis_deg          REAL,
    mean_anomaly_deg                REAL,
    orbital_period_days             REAL,
    perihelion_au                   REAL,
    aphelion_au                     REAL,
    mean_motion_deg_per_day         REAL,
    updated_at                      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

----------------------------------------------------------------------
-- Physical properties
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS physical_properties (
    object_id                   TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,
    radius_km                   REAL,         -- mean / volumetric radius
    equatorial_radius_km        REAL,
    polar_radius_km             REAL,
    mass_kg                     REAL,
    density_g_cm3               REAL,
    rotation_period_hours       REAL,         -- sidereal
    axial_tilt_deg              REAL,
    surface_gravity_m_s2        REAL,
    escape_velocity_km_s        REAL,
    updated_at                  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

----------------------------------------------------------------------
-- Visual properties (albedo, magnitude, colour)
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS visual_properties (
    object_id              TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,
    geometric_albedo       REAL,
    bond_albedo            REAL,
    absolute_magnitude_h   REAL,
    colour_b_v             REAL,
    spectral_type          TEXT,
    dominant_colour_hex    TEXT,            -- best-effort, for rendering models
    updated_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

----------------------------------------------------------------------
-- Rings (planet-level)
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id       TEXT NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    inner_radius_km REAL,
    outer_radius_km REAL,
    width_km        REAL,
    thickness_km    REAL,
    notes           TEXT
);
CREATE INDEX IF NOT EXISTS idx_rings_parent ON rings(parent_id);

----------------------------------------------------------------------
-- Provenance: which upstream source each fact came from
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    object_id       TEXT REFERENCES objects(id) ON DELETE CASCADE,
    table_name      TEXT NOT NULL,                 -- 'orbital_elements','physical_properties',...
    field_name      TEXT,                          -- nullable: whole-row provenance
    source_name     TEXT NOT NULL,                 -- 'JPL Horizons','JPL SBDB','MPC','NASA Fact Sheet'
    source_url      TEXT,
    retrieved_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_sources_object ON sources(object_id);
CREATE INDEX IF NOT EXISTS idx_sources_name   ON sources(source_name);

----------------------------------------------------------------------
-- Build metadata (one row per refresh run)
----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS build_meta (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at      TEXT NOT NULL,
    finished_at     TEXT,
    mode            TEXT NOT NULL,              -- 'full','nightly'
    row_count       INTEGER,
    notes           TEXT
);

----------------------------------------------------------------------
-- Convenience views
----------------------------------------------------------------------
DROP VIEW IF EXISTS v_planets;
CREATE VIEW v_planets AS
SELECT o.id, o.name, o.designation,
       p.radius_km, p.mass_kg, p.density_g_cm3, p.rotation_period_hours,
       p.axial_tilt_deg, p.surface_gravity_m_s2, p.escape_velocity_km_s,
       oe.semi_major_axis_au, oe.eccentricity, oe.inclination_deg,
       oe.orbital_period_days, oe.perihelion_au, oe.aphelion_au,
       vp.geometric_albedo, vp.dominant_colour_hex
FROM objects o
LEFT JOIN physical_properties p  ON p.object_id  = o.id
LEFT JOIN orbital_elements    oe ON oe.object_id = o.id
LEFT JOIN visual_properties   vp ON vp.object_id = o.id
WHERE o.object_type = 'planet'
ORDER BY oe.semi_major_axis_au;

DROP VIEW IF EXISTS v_moons_by_planet;
CREATE VIEW v_moons_by_planet AS
SELECT parent.name AS planet,
       o.id, o.name, o.designation, o.discoverer, o.discovery_date,
       p.radius_km, p.mass_kg,
       oe.semi_major_axis_au, oe.orbital_period_days, oe.eccentricity, oe.inclination_deg
FROM objects o
JOIN objects parent ON parent.id = o.parent_id
LEFT JOIN physical_properties p ON p.object_id = o.id
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
WHERE o.object_type = 'moon'
ORDER BY planet, oe.semi_major_axis_au;

DROP VIEW IF EXISTS v_dwarf_planets;
CREATE VIEW v_dwarf_planets AS
SELECT o.id, o.name, o.designation, o.object_type,
       p.radius_km, p.mass_kg,
       oe.semi_major_axis_au, oe.eccentricity, oe.inclination_deg,
       oe.orbital_period_days
FROM objects o
LEFT JOIN physical_properties p ON p.object_id = o.id
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
WHERE o.object_type IN ('dwarf_planet','dwarf_planet_candidate')
ORDER BY oe.semi_major_axis_au;

DROP VIEW IF EXISTS v_neos;
CREATE VIEW v_neos AS
SELECT o.id, o.name, o.designation,
       oe.semi_major_axis_au, oe.perihelion_au, oe.eccentricity, oe.inclination_deg,
       vp.absolute_magnitude_h
FROM objects o
JOIN classifications c ON c.object_id = o.id AND c.label = 'NEO'
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
LEFT JOIN visual_properties vp ON vp.object_id = o.id
ORDER BY vp.absolute_magnitude_h;

DROP VIEW IF EXISTS v_phas;
CREATE VIEW v_phas AS
SELECT o.id, o.name, o.designation,
       oe.semi_major_axis_au, oe.perihelion_au, oe.eccentricity,
       vp.absolute_magnitude_h
FROM objects o
JOIN classifications c ON c.object_id = o.id AND c.label = 'PHA'
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
LEFT JOIN visual_properties vp ON vp.object_id = o.id
ORDER BY vp.absolute_magnitude_h;

DROP VIEW IF EXISTS v_comets;
CREATE VIEW v_comets AS
SELECT o.id, o.name, o.designation, o.discoverer, o.discovery_date,
       oe.semi_major_axis_au, oe.eccentricity, oe.inclination_deg,
       oe.orbital_period_days, oe.perihelion_au, oe.aphelion_au
FROM objects o
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
WHERE o.object_type = 'comet'
ORDER BY oe.orbital_period_days;

DROP VIEW IF EXISTS v_tnos;
CREATE VIEW v_tnos AS
SELECT o.id, o.name, o.designation,
       oe.semi_major_axis_au, oe.eccentricity, oe.inclination_deg,
       oe.orbital_period_days,
       vp.absolute_magnitude_h
FROM objects o
LEFT JOIN orbital_elements oe ON oe.object_id = o.id
LEFT JOIN visual_properties vp ON vp.object_id = o.id
WHERE o.object_type IN ('tno','centaur')
ORDER BY oe.semi_major_axis_au;

DROP VIEW IF EXISTS v_object_counts;
CREATE VIEW v_object_counts AS
SELECT object_type, COUNT(*) AS n
FROM objects
GROUP BY object_type
ORDER BY n DESC;
