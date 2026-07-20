-- Photos de profil : une pièce jointe peut désormais n'appartenir à aucune
-- conversation, mais directement à un compte.
--
-- Écrite à la main plutôt que générée : `prisma migrate dev` proposait de
-- réinitialiser la base, ce qui aurait détruit les comptes et les blobs en
-- production. Rendre une colonne nullable et en ajouter une autre ne demande
-- aucune perte de données.
ALTER TABLE "attachment_refs" ALTER COLUMN "conversation_id" DROP NOT NULL;

ALTER TABLE "attachment_refs" ADD COLUMN "owner_user_id" UUID;

ALTER TABLE "attachment_refs"
  ADD CONSTRAINT "attachment_refs_owner_user_id_fkey"
  FOREIGN KEY ("owner_user_id") REFERENCES "users"("id")
  ON DELETE CASCADE ON UPDATE CASCADE;

-- Une pièce jointe appartient soit à une conversation, soit à un compte, jamais
-- ni l'un ni l'autre : sans cette contrainte, une ligne orpheline deviendrait
-- impossible à rattacher et son objet chiffré resterait indéfiniment chez
-- l'hébergeur, sans plus rien pour le retrouver ni le supprimer.
ALTER TABLE "attachment_refs"
  ADD CONSTRAINT "attachment_refs_owner_check"
  CHECK ("conversation_id" IS NOT NULL OR "owner_user_id" IS NOT NULL);
