import '../config/env.js'; // charge .env avant de lire DATABASE_URL
import { PrismaClient } from '@prisma/client';

export const prisma = new PrismaClient();
