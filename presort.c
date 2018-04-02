/*
 * Created 2018-03-12
 */

#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <string.h>

static char pathsep='/';

typedef struct {
    char *sz;
    char *atime;
    char *path;
} agedu_t;

/*
 * compare in ascii order except "/" takes precedence
 */
int strcmppathsep(const char *a, const char *b)
{
    while (*a == *b && *a)
        a++, b++;

    if (*b == pathsep && !*a) return -1;		// parent directory precedence
    if (*a == pathsep && !*b) return 1;		// parent directory precedence
    if (*a == pathsep) return -1;
    if (*b == pathsep) return 1;

    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/*
 * insertion sort is most efficienc when input is already mostly sorted, as it is with Starfish Database output
 */

int compareentries(const agedu_t *a, const agedu_t *b) {
    char *p;
    char *q;

    p = a->path;
    q = b->path;
    return strcmppathsep(p, q);
}

/*
 * insertion sort routine
 */
void insert_sort(agedu_t ** unsorted, const int nel) {
    int c, d;
    agedu_t ap, *p1, *p2;
    for (c = 1 ; c <= nel - 1; c++) {
	d = c;
    
	p1 = (*unsorted)+d-1;
	p2 = (*unsorted)+d;
	while ( d > 0 && compareentries(p1, p2) > 0) {
	    ap.sz = p2->sz;
	    ap.path = p2->path;
	    p2->sz = p1->sz;
	    p2->path = p1->path;
	    p1->sz = ap.sz;
	    p1->path = ap.path;
     
	    d--;
	    p1 = (*unsorted)+d-1;
	    p2 = (*unsorted)+d;
	}
    }
}

/*
 * print out the sorted list
 */
void printsorted(const agedu_t * adup, const int len) {
    int i;
    for (i = 0; i < len; i++) {
	printf("%s\n", (adup+i)->sz );
    }
}

static int debug=1;

main (const int argc, const char *argv[]) {
    int fd;
    int offset = 0;
    int rownum;
    
    size_t length;
    struct stat sb;
    agedu_t *presortlist, *adup;
    char *addr;
    char *p;
    char *header;	// saveheader for later
    char newline = (const char ) '\012';

    if (argc < 2 || argc > 2) {
	fprintf(stderr, "usage: %s <file> \n", argv[0]);
	exit(EXIT_FAILURE);
    }

    fd = open(argv[1], O_RDONLY);
    if (fd == -1) {
	fprintf(stderr,"Couldn't open input file %s, check permissions\n", argv[1]);
	exit(EXIT_FAILURE);
    }

    if (fstat(fd, &sb) == -1) {           /* To obtain file size */
	perror("failed fstat");
        exit(EXIT_FAILURE);
    }

    // setup all the pointers for sorting - arbitrarily limited to 1,000,000 entries
    presortlist = (agedu_t *) malloc(sizeof(agedu_t) * 1000000);
    if (presortlist == NULL) {
	perror("error allocating memory");
	exit(EXIT_FAILURE);
    }
    memset(presortlist, 0, sizeof(presortlist));
    adup = presortlist;

    offset = 0;
    length = sb.st_size;

    addr = mmap(NULL, length, PROT_READ|PROT_WRITE, MAP_PRIVATE, fd, offset);
    if (addr == MAP_FAILED) {
	perror("mmap failed");
        exit(EXIT_FAILURE);
    }

	
    /* skip header */
    p = header = addr;
    p = strchr(p, newline); 
    /* mark it and skip to first item */
    *p++ = (char) 0;

    rownum = 0;
    while (p < addr + length) {
	adup->sz = p;
	p = strchr(p, ' ') + 1;
	adup->atime = p;
	p = strchr(p, ' ') + 1;
	adup->path = p;
	p = strchr(p, newline);	// end of line and replace with null
	*p = (char) 0;
	p++;		// next row
	rownum++;
	adup++;
    }
    if (debug > 1)
        fprintf (stderr,"%d rows\n", rownum);

    insert_sort(&presortlist, rownum);

    printf("%s\n", header);
    printsorted((const agedu_t *) presortlist, rownum);

    /*qsort(names, nnames, sizeof(*names), str_cmp);*/

    return (EXIT_SUCCESS);
}
