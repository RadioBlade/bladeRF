/*
 * This file is part of the bladeRF project:
 *   http://www.github.com/nuand/bladeRF
 *
 * Copyright (C) 2015 Nuand LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include <getopt.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <signal.h>
#include <libbladeRF.h>
#include "test_common.h"
#include "conversions.h"
#include "host_config.h"
#include "include.h"
#include "devcfg.h"
#include "log.h"

#define VERBOSITY BLADERF_LOG_LEVEL_VERBOSE

#define BUF_LEN    8192
#define TIMEOUT_MS 2500
#define SAMPLE_RATE 2000000
#define BANDWIDTH   5000000

#define BLADERF2_CENTER_FREQ ((bladerf_frequency) 3.000e9)
#define BLADERF2_START_FREQ ((bladerf_frequency) 1.600e9)
#define BLADERF2_STOP_FREQ ((bladerf_frequency) 1.630e9)
#define ITERATIONS 500
#define DWELL_TIME (100000)
#define LINE_LENGTH 256

typedef struct frequency_sweep{
    bladerf_frequency start_sweep;
    bladerf_frequency stop_sweep;
    int step_count;
    int intersection;
    bladerf_timestamp step_duration;
    struct bladerf_quick_tune* quick_tunes;
} frequency_sweep;

typedef struct sweep_metadata{
    bladerf_direction dir;
    int sweep_format;
    frequency_sweep* sweep;
    int sweep_count;
    int quick_tune_count;
    bladerf_timestamp sweep_start_time;
    bladerf_timestamp sweep_period;
    bladerf_timestamp next_timestamp;
    int current_iter;
    int current_sweep;
    int current_step;
} sweep_metadata;

bool is_running = true;
struct devcfg config;

void sig_handler(int signo)
{
    if (signo == SIGINT) {
        fprintf(stderr, "received SIGINT\n");
        if (!is_running) {
            fprintf(stderr, "received another SIGINT, aborting\n");
            abort();
        }
        is_running = false;
    }
}


int countlines(char *filename)
{
    // count the number of lines in the file called filename                                    
    FILE *fp = fopen(filename,"r");
    int ch=0;
    int lines=0;

    if (fp == NULL){
        printf("could not open %s\n", filename);
        return 0;
    }

    lines++;
    while(!feof(fp)) {
        ch = fgetc(fp);
        if(ch == '\n') {
            lines++;
        }
    }

    fclose(fp);
    return lines;
}

int read_csv(char* filename, sweep_metadata* sweeps_meta){
    FILE *fp;
    char row[LINE_LENGTH];
    char *token;
    frequency_sweep* sweeps;
    char* result;
    int i=0;
    
    sweeps_meta->sweep_count=countlines(filename)-1;
    if(sweeps_meta->sweep_count==0){
        printf("empty file\n");
        return -1;
    }

    sweeps = (frequency_sweep*) malloc((sweeps_meta->sweep_count) * sizeof(frequency_sweep));
    if(sweeps==NULL){
        printf("could not malloc %d sweeps\n", sweeps_meta->sweep_count);
        return -1;
    }
    sweeps_meta->sweep = sweeps;


    // token = strtok(NULL, ",");
    // sweeps[i].stop_sweep=atoi(token);
    printf("bandwidth not implemented\n");

    fp = fopen(filename,"r");
    if (fp == NULL){
        printf("could not open %s\n", filename);
        free(sweeps);
        return -1;
    }

    result=fgets(row, LINE_LENGTH, fp);
    if(result==NULL) {
        printf("Could not read row: \"%s\" %ld\n", row, (long int) result);
        i--;
        return -1;
    }

    token = strtok(row, ",");
    sweeps_meta->sweep_format=atoi(token);
    printf("format: %s\n", token);
    
    while (feof(fp) != true)
    {
        result=fgets(row, LINE_LENGTH, fp);
        if(result==NULL) {
            printf("Could not read row: \"%s\" %ld\n", row, (long int) result);
            i--;
            return -1;
        }

        token = strtok(row, ",");
        sweeps[i].start_sweep=atol(token);
        printf("start: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].stop_sweep=atol(token);
        printf("stop: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].step_count=atoi(token);
        printf("count: %s\n", token);

        token = strtok(NULL, ",");
        sweeps[i].step_duration=atol(token);
        printf("duration: %s\n", token);
        // while(token != NULL)
        // {
        //     printf("Token: %s\n", token);
        //     token = strtok(NULL, ",");
        // }
        i++;
    }
    printf("\n");

    fclose(fp);
    return -1;
}


int get_current_scan_index(struct bladerf *dev, sweep_metadata* sweep_meta){
    int status;
    bladerf_timestamp current_timestamp;
    bladerf_timestamp calc_timestamp;
    int current_sweep;
    int i;

    status = bladerf_get_timestamp(dev, sweep_meta->dir, &current_timestamp);
    if(status!=0){
        fprintf(stderr, "Failed to get timestamp %s\n",
                bladerf_strerror(status));
        return status;
    }

    calc_timestamp = current_timestamp - sweep_meta->sweep_start_time;
    sweep_meta->current_iter = calc_timestamp/sweep_meta->sweep_period;
    calc_timestamp = calc_timestamp%sweep_meta->sweep_period;
    printf("%s %d\n", __FUNCTION__, __LINE__);

    for(current_sweep=0; current_sweep < sweep_meta->sweep_count; current_sweep++){
    printf("%s %d\n", __FUNCTION__, __LINE__);
        if(calc_timestamp < sweep_meta->sweep[current_sweep].step_count * sweep_meta->sweep[current_sweep].step_duration){
    printf("%s %d\n", __FUNCTION__, __LINE__);
            sweep_meta->current_step = calc_timestamp/sweep_meta->sweep[current_sweep].step_duration;
            break;
        } else{
    printf("%s %d\n", __FUNCTION__, __LINE__);
            calc_timestamp -= sweep_meta->sweep[current_sweep].step_count * sweep_meta->sweep[current_sweep].step_duration;
        }
    }
    printf("%s %d\n", __FUNCTION__, __LINE__);
    sweep_meta->current_sweep = current_sweep;
    sweep_meta->next_timestamp = sweep_meta->sweep_start_time + (sweep_meta->sweep_period*sweep_meta->current_iter);
    for(i=0;i<current_sweep-1;i++){
        sweep_meta->next_timestamp += sweep_meta->sweep[i].step_count*sweep_meta->sweep[i].step_duration;
    }
    printf("%s %d\n", __FUNCTION__, __LINE__);
    sweep_meta->next_timestamp += (sweep_meta->current_step+1)*sweep_meta->sweep[i].step_duration;


    return 0;
}

void get_next_scan_timestamp(struct bladerf *dev, sweep_metadata* sweep_meta){
    sweep_meta->next_timestamp += sweep_meta->sweep[sweep_meta->current_sweep].step_duration;
    printf("%s %d\n", __FUNCTION__, __LINE__);
    if(sweep_meta->current_step != sweep_meta->sweep[sweep_meta->current_sweep].step_count-1){
    printf("%s %d\n", __FUNCTION__, __LINE__);
        sweep_meta->current_step+=1;
    } else{
    printf("%s %d\n", __FUNCTION__, __LINE__);
        sweep_meta->current_step=0;
    printf("%s %d\n", __FUNCTION__, __LINE__);
        if(sweep_meta->current_sweep != sweep_meta->sweep_count-1){
    printf("%s %d\n", __FUNCTION__, __LINE__);
            sweep_meta->current_sweep+=1;
        } else {
    printf("%s %d\n", __FUNCTION__, __LINE__);
            sweep_meta->current_sweep=0;
            sweep_meta->current_iter+=1;
        }
    }
}


int run_test_retune_sender(struct bladerf *dev, sweep_metadata* sweep_meta)
{
    int status;
    int16_t *samples = NULL;
    struct bladerf_metadata meta;
    bladerf_module channel_layout;
    bladerf_frequency current_frequency;
    bladerf_frequency frequency_step;
    int i, j;

    memset(&meta, 0, sizeof(meta));

    sweep_meta->dir = BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_TX(0));

    samples = malloc(2 * BUF_LEN * sizeof(samples[0]));
    if (samples == NULL) {
        perror("malloc");
        return BLADERF_ERR_MEM;
    }

    /* Just send a carrier tone */
    for (i = 0; i < (2 * BUF_LEN); i += 2) {
        samples[i] = samples[i+1] = 1448;;
    }

    channel_layout = BLADERF_TX_X1;
    status = devcfg_perform_sync_config(dev, channel_layout,
                                        BLADERF_FORMAT_SC16_Q11_META,
                                        &config, true);
    if (status != 0) {
        bladerf_close(dev);
        return -1;
    }

    sweep_meta->quick_tune_count=0;
    sweep_meta->sweep_period=0;
    for(j=0;j<sweep_meta->sweep_count;j++){
        sweep_meta->quick_tune_count += sweep_meta->sweep[j].step_count;
        sweep_meta->sweep_period += sweep_meta->sweep[j].step_count*sweep_meta->sweep[j].step_duration;
    }

    if(sweep_meta->quick_tune_count>2048){ // TODO: find define
        printf("cannot set quick tune more than 2048 (currently %d)\n", sweep_meta->quick_tune_count);
        return -1;
    }

    for(i=0;i<sweep_meta->sweep_count;i++){
        // printf("i:%d/%d\n",i,sweep_meta->sweep_count);
        frequency_step = (sweep_meta->sweep[i].stop_sweep-sweep_meta->sweep[i].start_sweep)/sweep_meta->sweep[i].step_count;
        current_frequency=sweep_meta->sweep[i].start_sweep;
        sweep_meta->sweep[i].quick_tunes = (struct bladerf_quick_tune*) malloc(sizeof(struct bladerf_quick_tune)*sweep_meta->sweep[i].step_count);
        if(sweep_meta->sweep[i].quick_tunes==NULL){
            printf("could not allocate memory for sweep %d (%ld bytes)", i, sizeof(struct bladerf_quick_tune)*sweep_meta->sweep[i].step_count);
            return -1;
        }
        /* Get the quick tune data */
        for( j=0; j<sweep_meta->sweep[i].step_count; j++){
            // printf("freq:%ld, ", current_frequency);
            status = bladerf_set_frequency(dev, BLADERF_CHANNEL_TX(0), current_frequency);
            if(status!=0){
                fprintf(stderr, "Failed to set frequency to %" PRIu64 ": %s\n",
                        current_frequency, bladerf_strerror(status));
                return status;
            }

            status = bladerf_get_quick_tune(dev, BLADERF_CHANNEL_TX(0), &sweep_meta->sweep[i].quick_tunes[j]);
            if(status!=0){
                fprintf(stderr, "Failed to get quick tune %" PRIu64 ": %s\n",
                        current_frequency, bladerf_strerror(status));
                return status;
            }
            current_frequency+=frequency_step;
        }
        // printf("\n");
    }

    status = bladerf_get_timestamp(dev, BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_TX(0)), &sweep_meta->sweep_start_time);
    if(status!=0){
        fprintf(stderr, "Failed to get timestamp %s\n",
                bladerf_strerror(status));
        return status;
    }

    meta.timestamp = sweep_meta->sweep_start_time + sweep_meta->sweep[0].step_duration; //TODO: Should assign a valid and smallest possible delay
    for( i=0; i<sweep_meta->sweep_count; i++){
        for( j=0; j<sweep_meta->sweep[i].step_count; j++){
            status = bladerf_schedule_retune(dev, BLADERF_CHANNEL_TX(0), meta.timestamp+i*sweep_meta->sweep_period, 0, &sweep_meta->sweep[i].quick_tunes[j]);
            // printf("%d. setting retune to %ld (%ld)\n", i, meta->timestamp, meta->timestamp/1000000);
            if (status != 0) {
                fprintf(stderr, "Failed to apply quick tune: %s\n",
                        bladerf_strerror(status));
                return status;
            }
            meta.timestamp += sweep_meta->sweep[i].step_duration;
        }
    }

    status = get_current_scan_index(dev, sweep_meta);
    if(status!=0){
        fprintf(stderr, "Failed to get current _scan index\n");
        return status;
    }

    meta.timestamp = sweep_meta->next_timestamp;
    while(1) {
        printf("sync tx------------------------\n");
        status = bladerf_sync_tx(dev, samples, BUF_LEN, &meta, TIMEOUT_MS);
        if (status != 0) {
            fprintf(stderr, "Failed to RX data: %s\n",
                    bladerf_strerror(status));
            goto out;
        }
        printf("--------------------------------------tx\n\n");

        status = bladerf_schedule_retune(dev, BLADERF_CHANNEL_TX(0), meta.timestamp+sweep_meta->sweep_period, 0, &sweep_meta->sweep[sweep_meta->current_sweep].quick_tunes[sweep_meta->current_step]);
        // printf("%d. setting retune to %ld (%ld)\n", i, meta->timestamp, meta->timestamp/1000000);
        if (status != 0) {
            fprintf(stderr, "Failed to apply quick tune: %s\n",
                    bladerf_strerror(status));
            return status;
        }

        get_next_scan_timestamp(dev, sweep_meta);
        meta.timestamp = sweep_meta->next_timestamp;

        // usleep(1000000);
    }

out:
    free(samples);
    printf("bladerf close------------------------\n");
    bladerf_enable_module(dev, BLADERF_CHANNEL_TX(0), false);
    printf("--------------------------------------\n\n");
    return status;
}

int run_test_retune_receiver(struct bladerf *dev, sweep_metadata* sweep_meta)
{
    int status;
    int16_t *samples = NULL;
    struct bladerf_metadata meta;
    bladerf_module channel_layout;
    bladerf_frequency current_frequency;
    bladerf_frequency frequency_step;
    int i, j;
    memset(&meta, 0, sizeof(meta));

    sweep_meta->dir = BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_RX(0));

    samples = malloc(2 * BUF_LEN * sizeof(samples[0]));
    if (samples == NULL) {
        perror("malloc");
        return BLADERF_ERR_MEM;
    }

    switch(sweep_meta->sweep_format){
        case 0:
        case 1:
        case 2:
        case 3:
        case 4:
        case 5: 
            channel_layout=BLADERF_RX_X1;
            break;
        case 6:
        case 7:
        case 8:
        case 9: 
        case 10: 
            channel_layout=BLADERF_RX_X2;
            break;
        default: 
            channel_layout=BLADERF_RX_X2;
            break;
    }
    status = devcfg_perform_sync_config(dev, channel_layout,
                                        BLADERF_FORMAT_SC16_Q11_META,
                                        &config, true);
    if (status != 0) {
        bladerf_close(dev);
        return -1;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    
    sweep_meta->quick_tune_count=0;
    sweep_meta->sweep_period=0;
    for(j=0;j<sweep_meta->sweep_count;j++){
        sweep_meta->quick_tune_count += sweep_meta->sweep[j].step_count;
        sweep_meta->sweep_period += sweep_meta->sweep[j].step_count*sweep_meta->sweep[j].step_duration;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    if(sweep_meta->quick_tune_count>2048){ // TODO: find define
        printf("cannot set quick tune more than 2048 (currently %d)\n", sweep_meta->quick_tune_count);
        return -1;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    for(i=0;i<sweep_meta->sweep_count;i++){
        // printf("i:%d/%d\n",i,sweep_meta->sweep_count);
        frequency_step = (sweep_meta->sweep[i].stop_sweep-sweep_meta->sweep[i].start_sweep)/sweep_meta->sweep[i].step_count;
        current_frequency=sweep_meta->sweep[i].start_sweep;
        sweep_meta->sweep[i].quick_tunes = (struct bladerf_quick_tune*) malloc(sizeof(struct bladerf_quick_tune)*sweep_meta->sweep[i].step_count);
        if(sweep_meta->sweep[i].quick_tunes==NULL){
            printf("could not allocate memory for sweep %d (%ld bytes)", i, sizeof(struct bladerf_quick_tune)*sweep_meta->sweep[i].step_count);
            return -1;
        }
        /* Get the quick tune data */
        printf("%s %d\n", __FUNCTION__, __LINE__);
        for( j=0; j<sweep_meta->sweep[i].step_count; j++){
            // printf("freq:%ld, ", current_frequency);
            status = bladerf_set_frequency(dev, BLADERF_CHANNEL_RX(0), current_frequency);
            if(status!=0){
                fprintf(stderr, "Failed to set frequency to %" PRIu64 ": %s\n",
                        current_frequency, bladerf_strerror(status));
                return status;
            }

            status = bladerf_get_quick_tune(dev, BLADERF_CHANNEL_RX(0), &sweep_meta->sweep[i].quick_tunes[j]);
            if(status!=0){
                fprintf(stderr, "Failed to get quick tune %" PRIu64 ": %s\n",
                        current_frequency, bladerf_strerror(status));
                return status;
            }
            current_frequency+=frequency_step;
        }
        // printf("\n");
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    status = bladerf_get_timestamp(dev, BLADERF_CHANNEL_IS_TX(BLADERF_CHANNEL_RX(0)), &sweep_meta->sweep_start_time);
    if(status!=0){
        fprintf(stderr, "Failed to get timestamp %s\n",
                bladerf_strerror(status));
        return status;
    }

    meta.timestamp = sweep_meta->sweep_start_time + sweep_meta->sweep[0].step_duration; //TODO: Should assign a valid and smallest possible delay
    printf("%s %d\n", __FUNCTION__, __LINE__);
    for( i=0; i<sweep_meta->sweep_count; i++){
        for( j=0; j<sweep_meta->sweep[i].step_count; j++){
            status = bladerf_schedule_retune(dev, BLADERF_CHANNEL_RX(0), meta.timestamp+i*sweep_meta->sweep_period, 0, &sweep_meta->sweep[i].quick_tunes[j]);
            // printf("%d. setting retune to %ld (%ld)\n", i, meta->timestamp, meta->timestamp/1000000);
            if (status != 0) {
                fprintf(stderr, "Failed to apply quick tune: %s\n",
                        bladerf_strerror(status));
                return status;
            }
            meta.timestamp += sweep_meta->sweep[i].step_duration;
        }
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    status = get_current_scan_index(dev, sweep_meta);
    if(status!=0){
        fprintf(stderr, "Failed to get current _scan index\n");
        return status;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);
    meta.timestamp = sweep_meta->next_timestamp;
    while(1) {
        printf("sync rx------------------------\n");
        status = bladerf_sync_rx(dev, samples, BUF_LEN, &meta, TIMEOUT_MS);
        if (status != 0) {
            fprintf(stderr, "Failed to RX data: %s\n",
                    bladerf_strerror(status));
            goto out;
        }
        printf("--------------------------------------tx\n\n");

        printf("%s %d\n", __FUNCTION__, __LINE__);
        status = bladerf_schedule_retune(dev, BLADERF_CHANNEL_RX(0), meta.timestamp+sweep_meta->sweep_period, 0, &sweep_meta->sweep[sweep_meta->current_sweep].quick_tunes[sweep_meta->current_step]);
        // printf("%d. setting retune to %ld (%ld)\n", i, meta->timestamp, meta->timestamp/1000000);
        if (status != 0) {
            fprintf(stderr, "Failed to apply quick tune: %s\n",
                    bladerf_strerror(status));
            return status;
        }

        get_next_scan_timestamp(dev, sweep_meta);
        meta.timestamp = sweep_meta->next_timestamp;

        printf("%s %d\n", __FUNCTION__, __LINE__);
        // usleep(1000000);
    }

out:
    free(samples);
    printf("bladerf close------------------------\n");
    bladerf_enable_module(dev, BLADERF_CHANNEL_RX(0), false);
    printf("--------------------------------------\n\n");
    return status;
}



int main(int argc, char *argv[])
{
    int i;
    int status;
    struct bladerf *dev = NULL;
    const char *devstr = NULL;
    sweep_metadata sweep_meta;

    printf("%s %d\n", __FUNCTION__, __LINE__);

    status = read_csv("deneme.csv", &sweep_meta);
    printf("sweep_count=%d\n", sweep_meta.sweep_count);
    for(i=0;i<sweep_meta.sweep_count;i++){
        printf("sweep_start=%lu\n", sweep_meta.sweep[i].start_sweep);
        printf("sweep_stop=%lu\n", sweep_meta.sweep[i].stop_sweep);
        printf("step_count=%d\n", sweep_meta.sweep[i].step_count);
        printf("step_duration=%lu\n", sweep_meta.sweep[i].step_duration);
    }

    

    printf("%s %d\n", __FUNCTION__, __LINE__);

    if (signal(SIGINT, sig_handler) == SIG_ERR) {
        fprintf(stderr, "Unable to catch SIGINT signals\n");
    }


    printf("%s %d\n", __FUNCTION__, __LINE__);

    bladerf_log_set_verbosity(VERBOSITY);


    printf("%s %d\n", __FUNCTION__, __LINE__);

    status = bladerf_open(&dev, devstr);
    if (status != 0) {
        fprintf(stderr, "Unable to open device: %s\n",
                bladerf_strerror(status));
        return status;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);

    devcfg_init(&config);
    config.rx_samplerate = SAMPLE_RATE;
    config.rx_bandwidth  = BANDWIDTH;

    config.samples_per_buffer = BUF_LEN;
    config.num_buffers = 16;
    config.num_transfers = 8;

    status = devcfg_apply(dev, &config);
    if (status != 0) {
        fprintf(stderr, "Failed to configure device.\n");
        bladerf_close(dev);
        return -1;
    }

    printf("%s %d\n", __FUNCTION__, __LINE__);


    status = run_test_retune_receiver(dev, &sweep_meta);
    if (status != 0) {
        fprintf(stderr, "Failed at run test: %s\n",
                bladerf_strerror(status));
        // bladerf_close(dev);
        // return -1;
    }    

    // status = run_test_retune_sender(dev, &sweep_meta);
    // if (status != 0) {
    //     fprintf(stderr, "Failed at run test: %s\n",
    //             bladerf_strerror(status));
    //     // bladerf_close(dev);
    //     // return -1;
    // }    

    printf("%s %d\n", __FUNCTION__, __LINE__);

    status = bladerf_enable_module(dev, BLADERF_RX_X1, false);
    if (status != 0) {
        fprintf(stderr, "Failed to status RX module: %s\n",
                bladerf_strerror(status));
        bladerf_close(dev);
        return -1;
    }    


    printf("%s %d\n", __FUNCTION__, __LINE__);

    status = bladerf_enable_module(dev, BLADERF_TX_X1, false);
    if (status != 0) {
        fprintf(stderr, "Failed to status TX module: %s\n",
                bladerf_strerror(status));
        bladerf_close(dev);
        return -1;
    }    

    bladerf_close(dev);
    return status;


}
