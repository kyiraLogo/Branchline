-- Branchline: optional demo project (code DEMO42, every person's PIN is 1111).
-- Run after schema.sql. Safe to skip. Re-running it replaces the demo project.

delete from public.projects where code = 'DEMO42';

insert into public.projects (code, name, root_id)
values ('DEMO42', 'Harbor Bridge Renovation (demo)', 'd1');

insert into public.nodes (id, project_code, parent_id, sort_order, name, role, pin_hash, goals, subgoals) values
('d1', 'DEMO42', null, 1, 'Marta Kowalska', 'Project Manager', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d1g0","text":"Approve final budget","pct":100},{"id":"d1g1","text":"Sign contractor agreements","pct":80},{"id":"d1g2","text":"Hand the bridge over to the city","pct":20}]',
 '[{"id":"d1s0","text":"Book a slot with the city council","done":false,"shared":true},{"id":"d1s1","text":"Draft the press note","done":false,"shared":false}]');

insert into public.nodes (id, project_code, parent_id, sort_order, name, role, pin_hash, goals, subgoals) values
('d2', 'DEMO42', 'd1', 1, 'Jonas Berg', 'Civil Lead', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d2g0","text":"Complete pier repairs","pct":70},{"id":"d2g1","text":"Resurface the deck","pct":35},{"id":"d2g2","text":"Upgrade drainage","pct":50}]',
 '[{"id":"d2s0","text":"Order core samples for pier 2","done":true,"shared":true},{"id":"d2s1","text":"Ask Ines for the revised load table","done":false,"shared":true},{"id":"d2s2","text":"Review the crane booking","done":false,"shared":false}]'),
('d3', 'DEMO42', 'd1', 2, 'Ana Petric', 'Procurement Lead', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d3g0","text":"Steel order delivered","pct":100},{"id":"d3g1","text":"Asphalt supplier confirmed","pct":100},{"id":"d3g2","text":"Spare parts in stock","pct":40}]',
 '[{"id":"d3s0","text":"Renegotiate delivery fee","done":false,"shared":false}]'),
('d4', 'DEMO42', 'd1', 3, 'Luka Novak', 'Safety Officer', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d4g0","text":"Safety plan approved","pct":100},{"id":"d4g1","text":"Weekly site audits","pct":60}]',
 '[]');

insert into public.nodes (id, project_code, parent_id, sort_order, name, role, pin_hash, goals, subgoals) values
('d5', 'DEMO42', 'd2', 1, 'Ines Horvat', 'Structural Engineer', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d5g0","text":"Load calculations signed off","pct":90},{"id":"d5g1","text":"Pier 3 reinforcement drawings","pct":55}]',
 '[{"id":"d5s0","text":"Check weld spec with Jonas","done":false,"shared":true}]'),
('d6', 'DEMO42', 'd2', 2, 'Tomasz Wrona', 'Site Foreman', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d6g0","text":"Crew schedule for November","pct":100},{"id":"d6g1","text":"Scaffold inspection passed","pct":40},{"id":"d6g2","text":"Night shift permits","pct":0}]',
 '[{"id":"d6s0","text":"Confirm Saturday crew","done":false,"shared":true}]'),
('d7', 'DEMO42', 'd3', 1, 'Eva Kralj', 'Buyer', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d7g0","text":"Quotes from three suppliers","pct":100},{"id":"d7g1","text":"Purchase orders issued","pct":100}]',
 '[]'),
('d8', 'DEMO42', 'd4', 1, 'Marko Zupan', 'Inspector', extensions.crypt('1111', extensions.gen_salt('bf')),
 '[{"id":"d8g0","text":"Inspection checklist drafted","pct":100},{"id":"d8g1","text":"Pier 1 inspected","pct":100},{"id":"d8g2","text":"Pier 2 inspected","pct":30}]',
 '[]');
