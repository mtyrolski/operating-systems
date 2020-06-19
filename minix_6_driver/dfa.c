#include <minix/drivers.h>
#include <minix/chardriver.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <minix/ds.h>
#include <minix/ioctl.h>
#include <sys/ioc_dfa.h>

/* Function prototypes for the driver. */
static int dfa_open(devminor_t minor, int access, endpoint_t user_endpt);
static int dfa_close(devminor_t minor);
static ssize_t dfa_read(devminor_t minor, u64_t position, endpoint_t endpt,
    cp_grant_id_t grant, size_t size, int flags, cdev_id_t id);
static int dfa_ioctl(devminor_t minor, unsigned long request, endpoint_t endpt,
    cp_grant_id_t grant, int flags, endpoint_t user_endpt, cdev_id_t id);

static ssize_t dfa_write(devminor_t UNUSED(minor), u64_t UNUSED(position),
    endpoint_t endpt, cp_grant_id_t grant, size_t size, int UNUSED(flags),
    cdev_id_t UNUSED(id));

/* SEF functions and variables. */
static void sef_local_startup(void);
static int sef_cb_init(int type, sef_init_info_t *info);
static int sef_cb_lu_state_save(int);
static int lu_state_restore(void);

/* Entry points to the driver. */
static struct chardriver dfa_tab =
{
    .cdr_open	= dfa_open,
    .cdr_close	= dfa_close,
    .cdr_read	= dfa_read,
    .cdr_ioctl  = dfa_ioctl,
    .cdr_write	= dfa_write
};

#define SIGMA 256
#define SIGMA_SHIFT 8
#define IOCTL_BUFF_SIZE 5

/* Automata State */
static unsigned char state;

/* Delta function */
/* f(state, char) = delta[SIGMA*state + char] */
static unsigned char delta[SIGMA*SIGMA];

/* Accept */
static unsigned char accept_state[SIGMA];


#define BUF_SIZE 1024
static char random_buff[BUF_SIZE];

static ssize_t dfa_read(devminor_t UNUSED(minor), u64_t UNUSED(position),
    endpoint_t endpt, cp_grant_id_t grant, size_t size, int UNUSED(flags),
    cdev_id_t UNUSED(id))
{
/* Read from one of the driver's minor devices. */
  size_t offset, chunk;
  int r;
  if(accept_state[state] != 0) {
    memset(random_buff, 'Y' , size < BUF_SIZE ? size : BUF_SIZE);
  }else {
    memset(random_buff, 'N' , size < BUF_SIZE ? size : BUF_SIZE);
  }

  for (offset = 0; offset < size; offset += chunk) {
    chunk = MIN(size - offset, BUF_SIZE);
    r = sys_safecopyto(endpt, grant, offset, (vir_bytes)random_buff, chunk);
    if (r != OK) {
        printf("random: sys_safecopyto failed for proc %d, grant %d\n",
            endpt, grant);
        return r;
    }
  }

  return size;
}

static ssize_t dfa_write(devminor_t UNUSED(minor), u64_t UNUSED(position),
    endpoint_t endpt, cp_grant_id_t grant, size_t size, int UNUSED(flags),
    cdev_id_t UNUSED(id))
{
/* Write to one of the driver's minor devices. */
  size_t offset, chunk;
  int r;
  for (offset = 0; offset < size; offset += chunk) {
    chunk = MIN(size - offset, BUF_SIZE);
    r = sys_safecopyfrom(endpt, grant, offset, (vir_bytes)random_buff,
        chunk);
    if (r != OK) {
        printf(": sys_safecopyfrom failed for proc %d,"
            " grant %d\n", endpt, grant);
        return r;
    }
    for(int j = 0; j < chunk; ++j) {
        unsigned char mark = (unsigned char)random_buff[j]; 

        state = delta[(((int)state) << SIGMA_SHIFT) + (int)mark];
    }
  }

  return size;
}


static int dfa_open(devminor_t UNUSED(minor), int UNUSED(access),
    endpoint_t UNUSED(user_endpt))
{
    return OK;
}

static int dfa_close(devminor_t UNUSED(minor))
{
    return OK;
}


static int dfa_ioctl(devminor_t UNUSED(minor), unsigned long request, endpoint_t endpt,
    cp_grant_id_t grant, int UNUSED(flags), endpoint_t user_endpt, cdev_id_t UNUSED(id))
{
    int rc;
    char buff[IOCTL_BUFF_SIZE];
    switch(request) {
    case DFAIOCRESET:
        state = 0;
        rc = OK;
        break;

    case DFAIOCADD:
        rc = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) buff, 3);
        if(rc == OK) {
            state = 0;
            unsigned char a = buff[0];
            unsigned char b = buff[1];
            delta[((int)a << SIGMA_SHIFT) +(int)b] = (unsigned char)buff[2];
        }
        break;

    case DFAIOCACCEPT:
        rc = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) buff, 1);
        if(rc == OK) {
            unsigned char c = buff[0];
            accept_state[(int)c] = 1;
        }

        break;
    
    case DFAIOCREJECT:
        rc = sys_safecopyfrom(endpt, grant, 0, (vir_bytes) buff, 1);
        if(rc == OK) {
            unsigned char c = buff[0];
            accept_state[(int)c] = 0;
        }

        break;

    default:
        rc = ENOTTY;
    }

    return rc;
}

static int sef_cb_lu_state_save(int UNUSED(state)) {
    int rc;
    if((rc = ds_publish_u32("state", state, DSF_OVERWRITE)) != OK) return rc;
    if((rc = ds_publish_mem("delta", delta, SIGMA*SIGMA, DSF_OVERWRITE)) != OK) return rc;
    if((rc = ds_publish_mem("accept_state", accept_state, SIGMA, DSF_OVERWRITE)) != OK) return rc;
    return OK;
}

static int lu_state_restore() {
    size_t size;
    uint32_t val;
    size = 1;
    int rc;
    if((rc = ds_retrieve_u32("state", &val)) != OK) {
        return rc;
    }

    state = (unsigned char)val;

    size = SIGMA*SIGMA;
    if((rc = ds_retrieve_mem("delta", delta, &size)) != OK) {
        return rc;
    }

    size = SIGMA;
    if((rc = ds_retrieve_mem("accept_state", accept_state, &size)) != OK) {
        return rc;
    }

    return OK;
}

static void initialize_local_vars() {
    memset(delta, 0, SIGMA*SIGMA );
    memset(accept_state, 0, SIGMA );
    state = 0;
}

static void sef_local_startup()
{
    /* Register init callbacks. Use the same function for all event types. */
    sef_setcb_init_fresh(sef_cb_init);
    sef_setcb_init_lu(sef_cb_init);
    sef_setcb_init_restart(sef_cb_init);

    /* Register live update callbacks. */
    /* - Agree to update immediately when LU is requested in a valid state. */
    sef_setcb_lu_prepare(sef_cb_lu_prepare_always_ready);
    /* - Support live update starting from any standard state. */
    sef_setcb_lu_state_isvalid(sef_cb_lu_state_isvalid_standard);
    /* - Register a custom routine to save the state. */
    sef_setcb_lu_state_save(sef_cb_lu_state_save);

    /* Let SEF perform startup. */
    sef_startup();
}

static int sef_cb_init(int type, sef_init_info_t *UNUSED(info))
{
    /* Initialize the driver. */
    int do_announce_driver = TRUE;

    switch(type) {
        case SEF_INIT_FRESH:
        initialize_local_vars();
        break;

        case SEF_INIT_LU:
            lu_state_restore();
            do_announce_driver = FALSE;
        break;

        case SEF_INIT_RESTART:
        initialize_local_vars();
        break;
    }

    /* Announce we are up when necessary. */
    if (do_announce_driver) {
        chardriver_announce();
    }

    /* Initialization completed successfully. */
    return OK;
}

int main(void)
{
    /* Perform initialization. */
    sef_local_startup();

    /* Run the main loop. */
    chardriver_task(&dfa_tab);
    return OK;
}