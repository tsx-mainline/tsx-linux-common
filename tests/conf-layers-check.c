/* Check of base/src/tsx-conf.h. Usage: conf-layers-check NAME KEY USER [BOARD [RUN]]
 * Prints the value of KEY after the layers (the last one wins), the number of
 * layer files that it read, and the layers in order, for example
 *   value=u files=3 layers=0,1,2
 * An empty argument counts as no file. */
#include <stdio.h>
#include <string.h>
#include "../base/src/tsx-conf.h"

struct ctx { const char *key; char value[256]; int layers[4], n; };

static void layer(const char *path, int l, void *arg)
{
	struct ctx *c = arg; FILE *f = fopen(path, "r"); char line[512]; size_t kl = strlen(c->key);
	c->layers[c->n++] = l;
	if (!f) return;
	while (fgets(line, sizeof line, f)) {
		line[strcspn(line, "\n")] = 0;
		if (!strncmp(line, c->key, kl) && line[kl] == '=') snprintf(c->value, sizeof c->value, "%s", line + kl + 1);
	}
	fclose(f);
}

int main(int argc, char **argv)
{
	struct ctx c = { argv[2], "", { 0 }, 0 };
	const char *b = argc > 4 ? argv[4] : NULL, *r = argc > 5 ? argv[5] : NULL;
	if (argc < 4) return 2;
	int n = tsx_conf_each(argv[1], b, argv[3], r, layer, &c);
	printf("value=%s files=%d layers=", c.value, n);
	for (int i = 0; i < c.n; i++) printf("%s%d", i ? "," : "", c.layers[i]);
	printf("\n");
	return 0;
}
