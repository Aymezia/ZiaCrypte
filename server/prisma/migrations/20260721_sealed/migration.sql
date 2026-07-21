-- Expéditeur scellé : le serveur accepte un dépôt sans savoir qui l'envoie.
--
-- Le jeton de remise est stocké HACHÉ : le serveur doit reconnaître un jeton
-- présenté, pas le retrouver ni le distribuer. Sa valeur en clair ne circule
-- que dans le canal chiffré, vers des correspondants avec qui une session
-- existe déjà.
ALTER TABLE "devices" ADD COLUMN "delivery_token_hash" TEXT;
CREATE UNIQUE INDEX "devices_delivery_token_hash_key"
  ON "devices"("delivery_token_hash");

-- Expéditeur et conversation deviennent facultatifs sur un blob : c'était
-- précisément ce que le serveur observait du graphe social. Les garder
-- obligatoires aurait vidé le scellement de son sens.
ALTER TABLE "message_blobs" ALTER COLUMN "sender_device_id" DROP NOT NULL;
ALTER TABLE "message_blobs" ALTER COLUMN "conversation_id" DROP NOT NULL;
