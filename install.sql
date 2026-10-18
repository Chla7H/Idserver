-- Optional: the script creates/updates this table automatically on start.
CREATE TABLE IF NOT EXISTS `player_ids` (
  `license` VARCHAR(60) NOT NULL,
  `custom_id` INT UNSIGNED NOT NULL,
  `name_override` VARCHAR(20) NULL,
  `font` VARCHAR(30) NULL,
  `name_color` VARCHAR(7) NULL,
  `id_color` VARCHAR(7) NULL,
  PRIMARY KEY (`license`),
  UNIQUE KEY `custom_id` (`custom_id`)
);
