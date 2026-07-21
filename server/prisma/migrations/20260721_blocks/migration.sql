-- Blocage de compte, appliqué côté serveur.
--
-- Un blocage qui ne vivrait que dans l'application laisserait la personne
-- bloquée déposer des blobs et consommer du stockage. Le serveur ne peut pas
-- lire ces messages, mais il sait qui écrit à qui — c'est ce qu'il faut pour
-- les refuser.
CREATE TABLE "blocks" (
    "blocker_user_id" UUID NOT NULL,
    "blocked_user_id" UUID NOT NULL,
    "created_at"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "blocks_pkey" PRIMARY KEY ("blocker_user_id", "blocked_user_id")
);

CREATE INDEX "blocks_blocked_user_id_idx" ON "blocks"("blocked_user_id");

ALTER TABLE "blocks" ADD CONSTRAINT "blocks_blocker_user_id_fkey"
  FOREIGN KEY ("blocker_user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "blocks" ADD CONSTRAINT "blocks_blocked_user_id_fkey"
  FOREIGN KEY ("blocked_user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
