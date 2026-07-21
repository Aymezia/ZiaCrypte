-- Compte administrateur : rôle, jeton de réinitialisation, journal d'actions.
--
-- Écrite à la main : `prisma migrate dev` proposait une réinitialisation, qui
-- détruirait comptes et blobs en production. Ajouter des colonnes NULLABLES et
-- une table ne demande aucune perte de données.

CREATE TYPE "UserRole" AS ENUM ('user', 'admin');

ALTER TABLE "users" ADD COLUMN "role" "UserRole" NOT NULL DEFAULT 'user';
ALTER TABLE "users" ADD COLUMN "reset_token_hash" TEXT;
ALTER TABLE "users" ADD COLUMN "reset_expires_at" TIMESTAMP(3);

CREATE TABLE "admin_actions" (
    "id"            UUID NOT NULL,
    "actor_user_id" UUID NOT NULL,
    "action"        TEXT NOT NULL,
    "target_label"  TEXT,
    "target_id"     UUID,
    "reason"        TEXT,
    "created_at"    TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "admin_actions_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "admin_actions_created_at_idx" ON "admin_actions"("created_at");

-- Aucune clé étrangère vers users : la trace doit survivre à la suppression du
-- compte concerné, sinon supprimer un compte effacerait la preuve qu'on l'a
-- supprimé.
